defmodule Translatable.Validate do
  @moduledoc """
  Validates Translatable backend configuration and translation artifacts.

  Validation is the CI safety net for the Translatable workflow. It checks the
  configured runtime backend, scans current message modules, and compares source
  code against the committed artifacts produced by extraction, packaging, and
  deferral.

  The validator currently checks:

    * backend configuration shape
    * provider preparation
    * source message definitions against the configured interpolator
    * current message hashes against `priv/translatable/source`
    * lock hashes against the committed source manifest
    * runtime bundles for every configured language
    * runtime translation bindings against each message's parameter contract
    * orphaned messages left in source, lock, or runtime artifacts
    * active deferrals recorded in lock files

  Deferrals are treated as known gaps. Matching deferred lock or runtime gaps
  are warnings rather than errors, which allows an urgent or feature-flagged
  source change to ship with source-language runtime fallbacks while translation
  work is still pending.

  The Mix task wrapper is `mix translatable.validate`.
  """

  alias Translatable.Bundle
  alias Translatable.Definition
  alias Translatable.Extract
  alias Translatable.Artifact
  alias Translatable.Module, as: TranslatableModule
  alias Translatable.Validation.Issue

  @spec validate(atom(), keyword()) :: {:ok, [Issue.t()]} | {:error, [Issue.t()]}
  def validate(app, opts \\ []) when is_atom(app) do
    backend = Keyword.get_lazy(opts, :backend, fn -> default_backend(app) end)

    issues =
      []
      |> add_backend_issues(app, backend)
      |> add_artifact_issues(app, backend, opts)

    if Enum.any?(issues, &(&1.severity == :error)) do
      {:error, issues}
    else
      {:ok, issues}
    end
  end

  defp default_backend(app) do
    Application.get_env(:translatable, :default_backend) ||
      app
      |> Application.get_env(:translatable, [])
      |> Keyword.get(:default_backend)
  end

  defp add_backend_issues(issues, app, nil) do
    [
      error(
        :missing_backend,
        "No default Translatable backend is configured for #{inspect(app)}"
      )
      | issues
    ]
  end

  defp add_backend_issues(issues, _app, backend) when is_atom(backend) do
    case Code.ensure_loaded(backend) do
      {:module, ^backend} ->
        issues
        |> validate_runtime_callback(backend)
        |> validate_backend_config(backend)
        |> validate_provider_setup(backend)

      _error ->
        [
          error(:backend_not_loaded, "Translatable backend #{inspect(backend)} is not loaded")
          | issues
        ]
    end
  end

  defp add_backend_issues(issues, _app, backend) do
    [
      error(:invalid_backend, "Translatable backend must be a module, got #{inspect(backend)}")
      | issues
    ]
  end

  defp validate_runtime_callback(issues, backend) do
    if function_exported?(backend, :__translatable_runtime__, 1) do
      issues
    else
      [
        error(
          :missing_runtime_callback,
          "#{inspect(backend)} does not expose __translatable_runtime__/1"
        )
        | issues
      ]
    end
  end

  defp validate_backend_config(issues, backend) do
    if function_exported?(backend, :__translatable_runtime__, 1) do
      source_lang = backend.__translatable_runtime__(:source_lang)
      langs = backend.__translatable_runtime__(:langs)
      bundle = backend.__translatable_runtime__(:bundle)
      providers = backend.__translatable_runtime__(:providers)
      {interpolator, _opts} = backend.__translatable_runtime__(:interpolator)

      issues
      |> require_binary(:invalid_source_lang, source_lang, "source_lang must be a string")
      |> require_binary_list(:invalid_langs, langs, "langs must be a non-empty list of strings")
      |> require_member(
        :source_lang_not_listed,
        source_lang,
        langs,
        "source_lang must be listed in langs"
      )
      |> reject_duplicates(:duplicate_langs, langs, "langs contains duplicate entries")
      |> require_bundle(bundle, backend)
      |> require_providers(providers)
      |> require_interpolator(interpolator)
    else
      issues
    end
  end

  defp validate_provider_setup(issues, backend) do
    if function_exported?(backend, :__translatable_runtime__, 1) do
      providers = backend.__translatable_runtime__(:providers)

      case Translatable.Runtime.prepare_providers(backend, providers) do
        :ok ->
          issues

        {:error, reason} ->
          [
            error(
              :provider_prepare_failed,
              "#{inspect(backend)} provider preparation failed: #{inspect(reason)}"
            )
            | issues
          ]
      end
    else
      issues
    end
  end

  defp add_artifact_issues(issues, _app, backend, _opts)
       when is_nil(backend) or not is_atom(backend) do
    issues
  end

  defp add_artifact_issues(issues, app, backend, opts) do
    if function_exported?(backend, :__translatable_runtime__, 1) do
      bundle = backend.__translatable_runtime__(:bundle)

      if match?(%Bundle{}, bundle) do
        issues
        |> validate_bundle_artifacts(app, backend, bundle, opts)
      else
        issues
      end
    else
      issues
    end
  end

  defp validate_bundle_artifacts(issues, app, backend, bundle, opts) do
    modules = Keyword.get_lazy(opts, :modules, fn -> Extract.discover_modules(app) end)
    definitions = definitions_from_modules(modules)
    source_shards = Bundle.source_shards(bundle, modules, opts)
    runtime_shards = Bundle.runtime_shards(bundle, modules)

    issues =
      validate_message_definitions(issues, definitions, backend)

    source_shards
    |> Enum.zip(runtime_shards)
    |> Enum.reduce(issues, fn {source_shard, runtime_shard}, acc ->
      shard_definitions = definitions_from_modules(source_shard.modules)
      current_manifest = Extract.build(source_shard.modules, app: app).manifest
      manifest_path = Keyword.get(opts, :manifest_path, source_shard.manifest_path)
      lock_path = Keyword.get(opts, :lock_path, runtime_shard.lock_path)
      runtime_path = Keyword.get(opts, :runtime_path, runtime_shard.runtime_path)

      acc
      |> validate_source_manifest(current_manifest, manifest_path)
      |> validate_lock(manifest_path, lock_path)
      |> validate_runtime_bundle(shard_definitions, backend, runtime_path, lock_path)
    end)
  end

  defp definitions_from_modules(modules) do
    modules
    |> Enum.map(fn module ->
      case module.__translatable__(:module) do
        %TranslatableModule{} = metadata -> metadata.messages
        _other -> []
      end
    end)
    |> List.flatten()
    |> Map.new(&{Definition.external_key(&1), &1})
  end

  defp validate_message_definitions(issues, definitions, backend) do
    interpolator = backend.__translatable_runtime__(:interpolator)

    Enum.reduce(definitions, issues, fn {key, definition}, acc ->
      validate_text_params(acc, key, "source", definition.source, definition, interpolator)
    end)
  end

  defp validate_source_manifest(issues, current_manifest, path) do
    with {:ok, saved} <- read_json(path, :missing_source_manifest, :invalid_source_manifest) do
      compare_manifest_messages(
        issues,
        current_manifest["messages"],
        saved["messages"] || [],
        path
      )
    else
      %Issue{} = issue -> [issue | issues]
    end
  end

  defp validate_lock(issues, manifest_path, path) do
    with {:ok, manifest} <-
           read_json(manifest_path, :missing_source_manifest, :invalid_source_manifest),
         {:ok, lock} <- read_json(path, :missing_lock, :invalid_lock) do
      compare_lock_messages(issues, manifest["messages"] || [], lock, path)
    else
      %Issue{} = issue -> [issue | issues]
    end
  end

  defp validate_runtime_bundle(issues, definitions, backend, path, lock_path) do
    with {:ok, runtime} <- read_json(path, :missing_runtime_bundle, :invalid_runtime_bundle) do
      lock =
        case read_json(lock_path, :missing_lock, :invalid_lock) do
          {:ok, lock} -> lock
          %Issue{} -> %{}
        end

      langs = backend.__translatable_runtime__(:langs)
      interpolator = backend.__translatable_runtime__(:interpolator)
      runtime_messages = runtime["messages"] || %{}
      deferred = Artifact.index_messages(lock["deferred"])

      definitions
      |> Enum.reduce(issues, fn {key, definition}, acc ->
        validate_runtime_message(
          acc,
          key,
          definition,
          langs,
          interpolator,
          runtime_messages,
          deferred
        )
      end)
      |> warn_orphan_runtime_keys(definitions, runtime_messages, path)
    else
      %Issue{} = issue -> [issue | issues]
    end
  end

  defp validate_runtime_message(
         issues,
         key,
         definition,
         langs,
         interpolator,
         runtime_messages,
         deferred
       ) do
    case Map.fetch(runtime_messages, key) do
      {:ok, translations} when is_map(translations) ->
        langs
        |> Enum.reduce(issues, fn lang, acc ->
          case Map.fetch(translations, lang) do
            {:ok, text} when is_binary(text) ->
              validate_text_params(acc, key, lang, text, definition, interpolator)

            {:ok, value} ->
              [
                error(
                  :invalid_runtime_translation,
                  "#{key} has non-string runtime translation for #{inspect(lang)}: #{inspect(value)}",
                  %{key: key, lang: lang}
                )
                | acc
              ]

            :error ->
              missing_runtime_translation_issue(acc, key, lang, deferred)
          end
        end)

      {:ok, value} ->
        [
          error(
            :invalid_runtime_message,
            "#{key} runtime bundle entry must be a map, got #{inspect(value)}",
            %{key: key}
          )
          | issues
        ]

      :error ->
        missing_runtime_message_issue(issues, key, deferred)
    end
  end

  defp missing_runtime_translation_issue(issues, key, lang, deferred) do
    if Map.has_key?(deferred, key) do
      [
        warning(
          :deferred_runtime_translation,
          "#{key} is missing runtime translation for #{inspect(lang)} but is deferred",
          %{key: key, lang: lang}
        )
        | issues
      ]
    else
      [
        error(
          :missing_runtime_translation,
          "#{key} is missing runtime translation for #{inspect(lang)}",
          %{key: key, lang: lang}
        )
        | issues
      ]
    end
  end

  defp missing_runtime_message_issue(issues, key, deferred) do
    if Map.has_key?(deferred, key) do
      [
        warning(
          :deferred_runtime_message,
          "#{key} is missing from runtime bundle but is deferred",
          %{key: key}
        )
        | issues
      ]
    else
      [
        error(:missing_runtime_message, "#{key} is missing from runtime bundle", %{key: key})
        | issues
      ]
    end
  end

  defp validate_text_params(issues, key, label, text, definition, interpolator) do
    case Translatable.Runtime.validate_interpolation(text, definition.params, interpolator) do
      :ok ->
        issues

      {:error, errors} ->
        Enum.reduce(errors, issues, fn message, acc ->
          [
            error(:invalid_bindings, "#{key} #{label} #{message}", %{
              key: key,
              label: label
            })
            | acc
          ]
        end)
    end
  end

  defp compare_manifest_messages(issues, current_messages, saved_messages, path) do
    current = index_list(current_messages)
    saved = index_list(saved_messages)

    issues
    |> compare_hashes(
      current,
      saved,
      ["source_hash", "params_hash", "definition_hash"],
      :source_manifest
    )
    |> warn_orphans(current, saved, :orphan_source_manifest_message, path)
  end

  defp compare_lock_messages(issues, current_messages, lock, path) do
    current = index_list(current_messages)
    lock_messages = lock["messages"] || %{}
    deferred = Artifact.index_messages(lock["deferred"])

    issues
    |> compare_hashes(
      current,
      lock_messages,
      ["source_hash", "params_hash", "definition_hash"],
      :lock,
      deferred
    )
    |> warn_orphans(current, lock_messages, :orphan_lock_message, path)
  end

  defp compare_hashes(issues, current, saved, fields, artifact, deferred \\ %{}) do
    Enum.reduce(current, issues, fn {key, current_message}, acc ->
      case Map.fetch(saved, key) do
        {:ok, saved_message} ->
          case first_stale_hash(current_message, saved_message, fields) do
            nil ->
              acc

            field ->
              stale_hash_issue(
                acc,
                key,
                current_message,
                saved_message,
                field,
                artifact,
                deferred
              )
          end

        :error ->
          missing_artifact_issue(acc, key, current_message, artifact, deferred)
      end
    end)
  end

  defp stale_hash_issue(issues, key, current_message, saved_message, field, artifact, deferred) do
    if deferred_matches?(key, current_message, deferred) do
      [
        warning(
          :deferred_stale_hash,
          "#{key} has stale #{field} in #{artifact} but is deferred",
          %{
            key: key,
            field: field,
            artifact: artifact
          }
        )
        | issues
      ]
    else
      [
        error(
          :stale_hash,
          "#{key} has stale #{field} in #{artifact}: expected #{current_message[field]}, got #{saved_message[field]}",
          %{key: key, field: field, artifact: artifact}
        )
        | issues
      ]
    end
  end

  defp missing_artifact_issue(issues, key, current_message, artifact, deferred) do
    if deferred_matches?(key, current_message, deferred) do
      [
        warning(
          :deferred_artifact_message,
          "#{key} is missing from #{artifact} but is deferred",
          %{
            key: key,
            artifact: artifact
          }
        )
        | issues
      ]
    else
      [
        error(:missing_artifact_message, "#{key} is missing from #{artifact}", %{
          key: key,
          artifact: artifact
        })
        | issues
      ]
    end
  end

  defp deferred_matches?(key, current_message, deferred) do
    case Map.fetch(deferred, key) do
      {:ok, deferred_message} -> deferred_message["source_hash"] == current_message["source_hash"]
      :error -> false
    end
  end

  defp first_stale_hash(current_message, saved_message, fields) do
    Enum.find(fields, &(current_message[&1] != saved_message[&1]))
  end

  defp warn_orphans(issues, current, saved, code, path) do
    current_keys = MapSet.new(Map.keys(current))

    saved
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(current_keys, &1))
    |> Enum.reduce(issues, fn key, acc ->
      [
        warning(code, "#{key} is present in #{path} but not current source", %{
          key: key,
          path: path
        })
        | acc
      ]
    end)
  end

  defp warn_orphan_runtime_keys(issues, definitions, runtime_messages, path) do
    current_keys = MapSet.new(Map.keys(definitions))

    runtime_messages
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(current_keys, &1))
    |> Enum.reduce(issues, fn key, acc ->
      [
        warning(:orphan_runtime_message, "#{key} is present in #{path} but not current source", %{
          key: key,
          path: path
        })
        | acc
      ]
    end)
  end

  defp index_list(messages) when is_list(messages), do: Map.new(messages, &{&1["key"], &1})
  defp index_list(_messages), do: %{}

  defp read_json(path, missing_code, invalid_code) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body) do
      {:ok, decoded}
    else
      {:error, :enoent} ->
        error(missing_code, "Missing Translatable artifact: #{path}", %{path: path})

      {:error, %Jason.DecodeError{} = reason} ->
        error(invalid_code, "Invalid JSON in #{path}: #{Exception.message(reason)}", %{path: path})

      {:error, reason} ->
        error(invalid_code, "Unable to read #{path}: #{inspect(reason)}", %{path: path})
    end
  end

  defp require_binary(issues, code, value, message) do
    if is_binary(value),
      do: issues,
      else: [error(code, "#{message}, got #{inspect(value)}") | issues]
  end

  defp require_binary_list(issues, code, values, message) do
    if is_list(values) and values != [] and Enum.all?(values, &is_binary/1) do
      issues
    else
      [error(code, "#{message}, got #{inspect(values)}") | issues]
    end
  end

  defp require_member(issues, code, value, values, message) do
    if is_list(values) and value in values, do: issues, else: [error(code, message) | issues]
  end

  defp reject_duplicates(issues, code, values, message) when is_list(values) do
    duplicates =
      values
      |> Enum.frequencies()
      |> Enum.filter(fn {_value, count} -> count > 1 end)
      |> Enum.map(fn {value, _count} -> value end)

    if duplicates == [] do
      issues
    else
      [error(code, "#{message}: #{inspect(duplicates)}") | issues]
    end
  end

  defp reject_duplicates(issues, _code, _values, _message), do: issues

  defp require_bundle(issues, %Bundle{}, _backend), do: issues

  defp require_bundle(issues, bundle, backend) do
    [
      error(
        :missing_bundle,
        "#{inspect(backend)} must configure a Translatable bundle, got #{inspect(bundle)}"
      )
      | issues
    ]
  end

  defp require_providers(issues, providers) when is_list(providers) and providers != [] do
    Enum.reduce(providers, issues, fn provider, acc ->
      {module, _opts} = normalize_provider(provider)

      cond do
        not is_atom(module) ->
          [error(:invalid_provider, "Provider must be a module, got #{inspect(provider)}") | acc]

        not Code.ensure_loaded?(module) or not function_exported?(module, :lookup, 3) ->
          [error(:invalid_provider, "#{inspect(module)} must implement lookup/3") | acc]

        true ->
          acc
      end
    end)
  end

  defp require_providers(issues, providers) do
    [
      error(:invalid_providers, "providers must be a non-empty list, got #{inspect(providers)}")
      | issues
    ]
  end

  defp require_interpolator(issues, module) do
    cond do
      not is_atom(module) ->
        [
          error(:invalid_interpolator, "Interpolator must be a module, got #{inspect(module)}")
          | issues
        ]

      not Code.ensure_loaded?(module) or not function_exported?(module, :interpolate, 4) ->
        [error(:invalid_interpolator, "#{inspect(module)} must implement interpolate/4") | issues]

      true ->
        issues
    end
  end

  defp normalize_provider({module, opts}) when is_list(opts), do: {module, opts}
  defp normalize_provider(module), do: {module, []}

  defp error(code, message, context \\ %{}) do
    %Issue{severity: :error, code: code, message: message, context: context}
  end

  defp warning(code, message, context) do
    %Issue{severity: :warning, code: code, message: message, context: context}
  end
end
