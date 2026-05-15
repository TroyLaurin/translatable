defmodule Translatable.Package do
  @moduledoc """
  Packages translated bundles into runtime JSON provider bundles.

  Packaging consumes translation input and writes the files that production code
  uses at runtime:

    * runtime bundles under `priv/translatable/runtime`
    * lock bundles under `priv/translatable/lock`

  Runtime bundles are intentionally small and optimized for lookup by
  `Translatable.Provider.Json`. Lock bundles record the source and definition
  hashes that those runtime translations cover. `mix translatable.validate`
  compares lock hashes against the committed source manifests so CI can detect
  missing or stale translations.

  Package input uses the canonical JSON translation format:

      {
        "format": "translatable.translations.v1",
        "messages": [
          {
            "key": "my_app:MyApp.Messages.greeting",
            "source_hash": "sha256:...",
            "params_hash": "sha256:...",
            "definition_hash": "sha256:...",
            "translations": [
              {"lang": "es", "text": "Hola {name}"}
            ]
          }
        ]
      }

  Multiple input files may be supplied. If the same message key appears in more
  than one input with different content, packaging fails rather than choosing an
  arbitrary winner.

  When packaging writes a message whose source hash matches an active deferred
  entry, that deferral is removed from the lock. This lets asynchronous
  translation updates close intentional gaps without a separate cleanup step.

  The Mix task wrapper is `mix translatable.package`.
  """

  alias Translatable.Artifact
  alias Translatable.Extract

  @translations_format "translatable.translations.v1"
  @runtime_format "translatable.runtime.v1"

  @spec write(
          atom(),
          module(),
          Translatable.Bundle.t(),
          Path.t() | [Path.t()] | {:stdin, String.t()},
          keyword()
        ) ::
          {:ok,
           %{
             runtime: Path.t(),
             lock: Path.t(),
             runtimes: [Path.t()],
             locks: [Path.t()],
             message_count: non_neg_integer(),
             translation_count: non_neg_integer()
           }}
          | {:error, [String.t()]}
  def write(app, backend, bundle, translations_path, opts \\ []) do
    modules = Keyword.get_lazy(opts, :modules, fn -> Extract.discover_modules(app) end)
    shards = Translatable.Bundle.runtime_shards(bundle, modules)

    with {:ok, translations} <- read_translations_input(translations_path),
         {:ok, written} <- write_shards(app, backend, bundle, translations, shards, opts) do
      Translatable.Bundle.write_runtime_manifests!(bundle, shards)
      Translatable.Bundle.write_lock_manifests!(bundle, shards)

      first = List.first(written)

      {:ok,
       %{
         runtime: first && first.runtime,
         lock: first && first.lock,
         runtimes: Enum.map(written, & &1.runtime),
         locks: Enum.map(written, & &1.lock),
         message_count: Enum.sum(Enum.map(written, & &1.message_count)),
         translation_count: Enum.sum(Enum.map(written, & &1.translation_count))
       }}
    end
  end

  @spec build([module()], map(), module(), keyword()) ::
          {:ok, %{runtime: map(), lock: map()}} | {:error, [String.t()]}
  def build(modules, translations, backend, opts \\ []) when is_list(modules) do
    app = Keyword.get(opts, :app)
    bundle = Keyword.get(opts, :bundle)
    source_lang = backend.__translatable_runtime__(:source_lang)
    packaged_langs = backend.__translatable_runtime__(:langs)

    current_messages =
      modules
      |> Extract.build(app: app)
      |> get_in([:extract, "messages"])

    translation_index = index_translations(translations)

    {messages, lock_messages, errors} =
      current_messages
      |> Enum.reduce({%{}, %{}, []}, fn message, {runtime_acc, lock_acc, errors} ->
        case runtime_message(message, translation_index, source_lang, packaged_langs) do
          {:ok, {key, translations}} ->
            {
              Map.put(runtime_acc, key, translations),
              Map.put(lock_acc, key, lock_message(message, source_lang, packaged_langs)),
              errors
            }

          {:error, message_errors} ->
            {runtime_acc, lock_acc, errors ++ message_errors}
        end
      end)

    stale_errors = stale_translation_errors(translation_index, current_messages)
    errors = errors ++ stale_errors

    if errors == [] do
      {:ok,
       %{
         runtime: %{
           "format" => @runtime_format,
           "messages" => Artifact.sort_message_map(messages)
         },
         lock:
           Artifact.lock_bundle(
             app,
             backend,
             bundle,
             source_lang,
             packaged_langs,
             lock_messages,
             remaining_deferred(Keyword.get(opts, :existing_lock), lock_messages)
           )
       }}
    else
      {:error, errors}
    end
  end

  @spec read_translations_input(Path.t() | {:stdin, String.t()}) ::
          {:ok, map()} | {:error, [String.t()]}
  def read_translations_input({:stdin, body}) when is_binary(body) do
    decode_translations(body, "stdin")
  end

  def read_translations_input(paths) when is_list(paths) do
    paths
    |> Enum.reduce_while({:ok, nil}, fn path, {:ok, acc} ->
      case read_translations_input(path) do
        {:ok, translations} ->
          merge_translation_inputs(acc, translations)

        {:error, _errors} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, nil} -> {:error, ["At least one translation input is required"]}
      result -> result
    end
  end

  def read_translations_input(path) when is_binary(path) do
    case File.read(path) do
      {:ok, body} ->
        decode_translations(body, path)

      {:error, :enoent} ->
        {:error, ["Translation input file not found: #{path}"]}

      {:error, reason} ->
        {:error, ["Unable to read translation input #{path}: #{inspect(reason)}"]}
    end
  end

  defp decode_translations(body, label) do
    with {:ok, decoded} <- Jason.decode(body),
         :ok <- validate_translation_format(decoded) do
      {:ok, decoded}
    else
      {:error, %Jason.DecodeError{} = reason} ->
        {:error, ["Invalid JSON in #{label}: #{Exception.message(reason)}"]}

      {:error, reasons} when is_list(reasons) ->
        {:error, reasons}

      {:error, reason} when is_binary(reason) ->
        {:error, [reason]}
    end
  end

  defp validate_translation_format(%{"format" => @translations_format, "messages" => messages})
       when is_list(messages) do
    errors =
      messages
      |> Enum.with_index()
      |> Enum.flat_map(fn {message, index} -> validate_translation_message(message, index) end)
      |> Kernel.++(duplicate_message_key_errors(messages))

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp validate_translation_format(_decoded),
    do: {:error, ["Translation input must use #{@translations_format} with a messages list"]}

  defp validate_translation_message(message, index) when is_map(message) do
    path = "/messages/#{index}"

    []
    |> require_binary(message, "key", path)
    |> require_hash(message, "source_hash", path)
    |> require_hash(message, "params_hash", path)
    |> require_hash(message, "definition_hash", path)
    |> validate_translations(message, path)
  end

  defp validate_translation_message(_message, index) do
    ["/messages/#{index} must be an object"]
  end

  defp require_binary(errors, message, field, path) do
    case Map.fetch(message, field) do
      {:ok, value} when is_binary(value) and value != "" -> errors
      {:ok, _value} -> ["#{path}/#{field} must be a non-empty string" | errors]
      :error -> ["#{path}/#{field} is required" | errors]
    end
  end

  defp require_hash(errors, message, field, path) do
    case Map.fetch(message, field) do
      {:ok, "sha256:" <> hex = value} when byte_size(hex) == 64 ->
        if String.match?(value, ~r/^sha256:[0-9a-f]{64}$/),
          do: errors,
          else: invalid_hash(errors, field, path)

      {:ok, _value} ->
        invalid_hash(errors, field, path)

      :error ->
        ["#{path}/#{field} is required" | errors]
    end
  end

  defp invalid_hash(errors, field, path),
    do: [
      "#{path}/#{field} must be a lowercase sha256 hash such as sha256:<64 hex chars>" | errors
    ]

  defp validate_translations(errors, message, path) do
    case Map.fetch(message, "translations") do
      {:ok, translations} when is_list(translations) ->
        translation_errors =
          translations
          |> Enum.with_index()
          |> Enum.flat_map(fn {translation, index} ->
            validate_translation(translation, "#{path}/translations/#{index}")
          end)

        duplicate_errors = duplicate_translation_lang_errors(translations, path)
        translation_errors ++ duplicate_errors ++ errors

      {:ok, _translations} ->
        ["#{path}/translations must be a list" | errors]

      :error ->
        ["#{path}/translations is required" | errors]
    end
  end

  defp validate_translation(translation, path) when is_map(translation) do
    []
    |> require_binary(translation, "lang", path)
    |> require_binary(translation, "text", path)
  end

  defp validate_translation(_translation, path), do: ["#{path} must be an object"]

  defp duplicate_message_key_errors(messages) do
    messages
    |> Enum.filter(&is_map/1)
    |> Enum.map(& &1["key"])
    |> duplicate_value_errors("message key", "/messages")
  end

  defp duplicate_translation_lang_errors(translations, path) do
    translations
    |> Enum.filter(&is_map/1)
    |> Enum.map(& &1["lang"])
    |> duplicate_value_errors("translation lang", "#{path}/translations")
  end

  defp duplicate_value_errors(values, label, path) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.frequencies()
    |> Enum.flat_map(fn
      {value, count} when count > 1 -> ["#{path} contains duplicate #{label} #{inspect(value)}"]
      {_value, _count} -> []
    end)
  end

  defp index_translations(%{"messages" => messages}) do
    Map.new(messages, fn message -> {message["key"], message} end)
  end

  defp merge_translation_inputs(nil, translations), do: {:cont, {:ok, translations}}

  defp merge_translation_inputs(%{"messages" => left} = acc, %{"messages" => right}) do
    case duplicate_translation_errors(left, right) do
      [] ->
        {:cont, {:ok, %{acc | "messages" => left ++ right}}}

      errors ->
        {:halt, {:error, errors}}
    end
  end

  defp duplicate_translation_errors(left, right) do
    left_index = Map.new(left, &{&1["key"], &1})

    right
    |> Enum.flat_map(fn message ->
      case Map.fetch(left_index, message["key"]) do
        {:ok, duplicate} when duplicate != message ->
          ["#{message["key"]} appears in multiple translation inputs with different content"]

        _other ->
          []
      end
    end)
  end

  defp write_shards(app, backend, bundle, translations, shards, opts) do
    shards
    |> Enum.reduce_while({:ok, []}, fn shard, {:ok, acc} ->
      runtime_path = Keyword.get(opts, :runtime_path, shard.runtime_path)
      lock_path = Keyword.get(opts, :lock_path, shard.lock_path)
      existing_lock = read_existing_lock(lock_path)

      case build(shard.modules, translations, backend,
             app: app,
             bundle: bundle,
             existing_lock: existing_lock
           ) do
        {:ok, package} ->
          write_json!(runtime_path, put_bundle_metadata(package.runtime, shard.metadata))
          write_json!(lock_path, put_bundle_metadata(package.lock, shard.metadata))

          written = %{
            runtime: runtime_path,
            lock: lock_path,
            message_count: map_size(package.runtime["messages"]),
            translation_count: translation_count(package.runtime)
          }

          {:cont, {:ok, [written | acc]}}

        {:error, _errors} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, written} -> {:ok, Enum.reverse(written)}
      {:error, _errors} = error -> error
    end
  end

  defp runtime_message(
         %{"key" => key, "translatable" => false} = current,
         _translation_index,
         _source_lang,
         packaged_langs
       ) do
    {:ok, {key, source_for_all_langs(current, packaged_langs)}}
  end

  defp runtime_message(%{"key" => key} = current, translation_index, source_lang, packaged_langs) do
    case Map.fetch(translation_index, key) do
      {:ok, translated} ->
        errors = fingerprint_errors(current, translated)
        translations = translated_texts(translated)

        missing_langs =
          packaged_langs
          |> Enum.reject(&(&1 == source_lang))
          |> Enum.reject(&Map.has_key?(translations, &1))

        errors =
          errors ++
            Enum.map(missing_langs, fn lang ->
              "#{key} is missing translation for #{inspect(lang)}"
            end)

        if errors == [] do
          {:ok, {key, take_langs(current, translations, source_lang, packaged_langs)}}
        else
          {:error, errors}
        end

      :error ->
        {:error, ["#{key} is missing from translation input"]}
    end
  end

  defp fingerprint_errors(current, translated) do
    [
      fingerprint_error(current, translated, "source_hash"),
      fingerprint_error(current, translated, "params_hash"),
      fingerprint_error(current, translated, "definition_hash")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp fingerprint_error(%{"key" => key} = current, translated, field) do
    if current[field] == translated[field] do
      nil
    else
      "#{key} has stale #{field}: expected #{current[field]}, got #{translated[field]}"
    end
  end

  defp translated_texts(%{"translations" => translations}) when is_list(translations) do
    translations
    |> Enum.filter(&(is_binary(&1["lang"]) and is_binary(&1["text"])))
    |> Map.new(fn translation -> {translation["lang"], translation["text"]} end)
  end

  defp translated_texts(_translated), do: %{}

  defp source_for_all_langs(current, packaged_langs) do
    packaged_langs
    |> Enum.reduce(%{}, fn lang, acc -> Map.put(acc, lang, current["source"]) end)
    |> Artifact.sort_message_map()
  end

  defp lock_message(current, source_lang, packaged_langs) do
    Artifact.lock_message(current, source_lang, packaged_langs)
  end

  defp take_langs(current, translations, source_lang, packaged_langs) do
    packaged_langs
    |> Enum.reduce(%{}, fn
      ^source_lang, acc -> Map.put(acc, source_lang, current["source"])
      lang, acc -> Map.put(acc, lang, Map.fetch!(translations, lang))
    end)
    |> Artifact.sort_message_map()
  end

  defp stale_translation_errors(translation_index, current_messages) do
    current_keys =
      current_messages
      |> Enum.map(& &1["key"])
      |> MapSet.new()

    translation_index
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(current_keys, &1))
    |> Enum.sort()
    |> Enum.map(&"#{&1} is present in translation input but not in current source")
  end

  defp translation_count(%{"messages" => messages}) do
    messages
    |> Map.values()
    |> Enum.map(&map_size/1)
    |> Enum.sum()
  end

  defp remaining_deferred(nil, _lock_messages), do: %{}

  defp remaining_deferred(%{"deferred" => deferred}, lock_messages) when is_map(deferred) do
    Enum.reject(deferred, fn {key, deferred_message} ->
      case Map.fetch(lock_messages, key) do
        {:ok, lock_message} -> deferred_message["source_hash"] == lock_message["source_hash"]
        :error -> false
      end
    end)
    |> Map.new()
  end

  defp remaining_deferred(_lock, _lock_messages), do: %{}

  defp put_bundle_metadata(bundle, metadata), do: Map.put(bundle, "bundle", metadata)

  defp read_existing_lock(path) do
    case Artifact.read_json(path) do
      {:ok, lock} -> lock
      {:error, _reason} -> nil
    end
  end

  defp write_json!(path, data) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(path, Jason.encode_to_iodata!(data, pretty: true))
  end
end
