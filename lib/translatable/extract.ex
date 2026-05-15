defmodule Translatable.Extract do
  @moduledoc """
  Builds deterministic source extraction artifacts for translatable modules.

  Extraction is the first workflow step after source code changes. It compiles
  the application, discovers modules implementing the `Translatable` behaviour,
  and writes two kinds of artifact:

    * a committed source manifest under `priv/translatable/source`
    * a full extract bundle under `_build/<env>/translatable/extract`

  The source manifest is compact. It stores message keys and hashes so CI can
  detect whether source code and committed translation state agree. The full
  extract includes source text, translator notes, parameters, pretranslated
  strings, and source locations. It is intended for transform and upload
  workflows and should not normally be committed.

  `Translatable.Bundle` controls whether extraction writes one file, one file
  per module, or custom grouped shards.

  The Mix task wrapper is `mix translatable.extract`.
  """

  alias Translatable.Definition
  alias Translatable.Module, as: TranslatableModule
  alias Translatable.Param

  @extract_format "translatable.extract.v1"
  @manifest_format "translatable.source-manifest.v1"

  @spec discover_modules(atom()) :: [module()]
  def discover_modules(app) when is_atom(app) do
    case :application.get_key(app, :modules) do
      {:ok, modules} ->
        modules
        |> Enum.filter(&translatable_module?/1)
        |> Enum.sort_by(&inspect/1)

      :undefined ->
        []
    end
  end

  @spec build([module()], keyword()) :: %{extract: map(), manifest: map()}
  def build(modules, opts \\ []) when is_list(modules) do
    app = Keyword.get(opts, :app)

    modules =
      modules
      |> Enum.map(&translatable_metadata!/1)
      |> Enum.sort_by(&inspect(&1.module))

    definitions =
      modules
      |> Enum.flat_map(& &1.messages)
      |> Enum.sort_by(&Definition.external_key/1)

    %{
      extract: extract_bundle(app, modules, definitions),
      manifest: manifest_bundle(app, definitions)
    }
  end

  @spec write(atom(), Translatable.Bundle.t(), keyword()) :: %{
          extract: Path.t(),
          manifest: Path.t()
        }
  def write(app, bundle, opts \\ []) when is_atom(app) do
    modules = Keyword.get_lazy(opts, :modules, fn -> discover_modules(app) end)
    source_shards = Translatable.Bundle.source_shards(bundle, modules, opts)
    runtime_shards = Translatable.Bundle.runtime_shards(bundle, modules)

    written =
      source_shards
      |> Enum.zip(runtime_shards)
      |> Enum.map(fn {source_shard, runtime_shard} ->
        output = build(source_shard.modules, app: app)

        manifest_path = Keyword.get(opts, :manifest_path, source_shard.manifest_path)
        extract_path = Keyword.get(opts, :extract_path, source_shard.extract_path)
        lock_path = Keyword.get(opts, :lock_path, runtime_shard.lock_path)

        warn_deferred_changes(output.manifest, lock_path)

        write_json!(manifest_path, put_bundle_metadata(output.manifest, source_shard.metadata))
        write_json!(extract_path, put_bundle_metadata(output.extract, source_shard.metadata))

        %{id: source_shard.id, extract: extract_path, manifest: manifest_path}
      end)

    Translatable.Bundle.write_source_manifests!(bundle, source_shards)
    Translatable.Bundle.write_extract_manifests!(bundle, source_shards, opts)

    first = List.first(written)

    %{
      extract: first && first.extract,
      manifest: first && first.manifest,
      extracts: Enum.map(written, & &1.extract),
      manifests: Enum.map(written, & &1.manifest)
    }
  end

  defp translatable_module?(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} -> function_exported?(module, :__translatable__, 1)
      _ -> false
    end
  end

  defp translatable_metadata!(module) do
    case module.__translatable__(:module) do
      %TranslatableModule{} = metadata ->
        metadata

      other ->
        raise ArgumentError,
              "#{inspect(module)} returned invalid Translatable metadata: #{inspect(other)}"
    end
  end

  defp extract_bundle(app, modules, definitions) do
    %{
      "format" => @extract_format,
      "application" => app_name(app),
      "modules" => Enum.map(modules, &module_to_json/1),
      "messages" => Enum.map(definitions, &definition_to_extract_json/1)
    }
  end

  defp manifest_bundle(app, definitions) do
    %{
      "format" => @manifest_format,
      "application" => app_name(app),
      "messages" => Enum.map(definitions, &definition_to_manifest_json/1)
    }
  end

  defp put_bundle_metadata(bundle, metadata), do: Map.put(bundle, "bundle", metadata)

  defp module_to_json(%TranslatableModule{} = module) do
    %{
      "module" => module_name(module.module),
      "application" => Atom.to_string(module.application),
      "source_lang" => module.source_locale,
      "message_count" => length(module.messages)
    }
  end

  defp definition_to_extract_json(%Definition{} = definition) do
    hashes = definition_hashes(definition)

    %{
      "key" => Definition.external_key(definition),
      "application" => Atom.to_string(definition.application),
      "module" => module_name(definition.module),
      "name" => Atom.to_string(definition.name),
      "arity" => definition.arity,
      "source_lang" => definition.source_locale,
      "source" => definition.source,
      "source_hash" => hashes.source_hash,
      "params_hash" => hashes.params_hash,
      "definition_hash" => hashes.definition_hash,
      "translatable" => definition.translatable?,
      "translator_note" => definition.translator_note,
      "params" => params_to_json(definition.params),
      "translations" => translations_to_json(definition.translations),
      "location" => location_to_json(definition.location)
    }
  end

  defp definition_to_manifest_json(%Definition{} = definition) do
    hashes = definition_hashes(definition)

    %{
      "key" => Definition.external_key(definition),
      "source_lang" => definition.source_locale,
      "source_hash" => hashes.source_hash,
      "params_hash" => hashes.params_hash,
      "definition_hash" => hashes.definition_hash,
      "translatable" => definition.translatable?
    }
  end

  defp definition_hashes(%Definition{} = definition) do
    source_fingerprint = [definition.source_locale, definition.source]
    params_fingerprint = params_to_json(definition.params)

    definition_fingerprint = [
      definition.source_locale,
      definition.source,
      definition.translator_note,
      definition.translatable?,
      params_fingerprint
    ]

    %{
      source_hash: stable_hash(source_fingerprint),
      params_hash: stable_hash(params_fingerprint),
      definition_hash: stable_hash(definition_fingerprint)
    }
  end

  defp params_to_json(params) do
    params
    |> Map.values()
    |> Enum.sort_by(&Atom.to_string(&1.name))
    |> Enum.map(fn %Param{} = param ->
      %{
        "name" => Atom.to_string(param.name),
        "type" => type_to_json(param.type),
        "note" => param.note
      }
    end)
  end

  defp translations_to_json(translations) do
    translations
    |> Enum.sort_by(fn {lang, _text} -> lang end)
    |> Enum.map(fn {lang, text} -> %{"lang" => lang, "text" => text} end)
  end

  defp type_to_json({:select, values}) when is_list(values) do
    %{
      "kind" => "select",
      "values" => Enum.map(values, &to_string/1)
    }
  end

  defp type_to_json(type) when is_atom(type), do: Atom.to_string(type)

  defp type_to_json(type), do: inspect(type)

  defp location_to_json(nil), do: nil

  defp location_to_json({file, line}) do
    %{
      "file" => Path.relative_to_cwd(file),
      "line" => line
    }
  end

  defp module_name(module) do
    module
    |> Atom.to_string()
    |> String.trim_leading("Elixir.")
  end

  defp app_name(nil), do: nil
  defp app_name(app) when is_atom(app), do: Atom.to_string(app)

  defp stable_hash(data) do
    encoded = Jason.encode!(data)
    digest = :crypto.hash(:sha256, encoded)

    "sha256:" <> Base.encode16(digest, case: :lower)
  end

  defp warn_deferred_changes(manifest, lock_path) do
    with {:ok, lock} <- Translatable.Artifact.read_json(lock_path) do
      current = Translatable.Artifact.index_messages(manifest["messages"])
      deferred = Translatable.Artifact.index_messages(lock["deferred"])

      Enum.each(deferred, fn {key, deferred_message} ->
        case Map.fetch(current, key) do
          {:ok, current_message} ->
            if Translatable.Artifact.first_stale_hash(current_message, deferred_message) do
              IO.warn(
                "#{key} has an active Translatable deferral but its source metadata changed; check whether the translation request must be resubmitted"
              )
            end

          :error ->
            :ok
        end
      end)
    end
  end

  defp write_json!(path, data) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(path, Jason.encode_to_iodata!(data, pretty: true))
  end
end
