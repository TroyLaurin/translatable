defmodule Translatable.Defer do
  @moduledoc """
  Defers outstanding translated strings by recording source-hash exceptions and
  writing source-language runtime fallbacks.

  Deferral is an explicit escape hatch for source changes that are safe to ship
  before translated strings have returned from a translation workflow. It should
  be used after extraction has updated the committed source manifest.

  The defer workflow:

    * requires the source manifest to match the current source code
    * finds messages whose lock or runtime bundle is missing or stale
    * records the current hashes in the lock file's optional `"deferred"`
      section
    * writes source text into the runtime bundle for every configured language
      so fallback chains still have a renderable string

  The task does not choose individual languages. A deferral covers every pending
  translation implied by the current source manifest, lock file, and runtime
  bundle. Optional `:reason` and `:link` values are stored with the deferred
  entry for local process or CI reporting.

  When `Translatable.Package` later writes translations for the deferred source
  hash, the matching deferred entry is removed.

  The Mix task wrapper is `mix translatable.defer`.
  """

  alias Translatable.Artifact
  alias Translatable.Bundle
  alias Translatable.Extract

  @spec write(atom(), module(), Bundle.t(), keyword()) ::
          {:ok, %{lock: Path.t(), runtime: Path.t(), deferred_count: non_neg_integer()}}
          | {:error, [String.t()]}
  def write(app, backend, bundle, opts \\ []) do
    modules = Keyword.get_lazy(opts, :modules, fn -> Extract.discover_modules(app) end)
    source_shards = Bundle.source_shards(bundle, modules, opts)
    runtime_shards = Bundle.runtime_shards(bundle, modules)

    with {:ok, results} <- write_shards(app, backend, source_shards, runtime_shards, opts) do
      Bundle.write_runtime_manifests!(bundle, runtime_shards)
      Bundle.write_lock_manifests!(bundle, runtime_shards)

      first = List.first(results)

      {:ok,
       %{
         lock: first && first.lock,
         runtime: first && first.runtime,
         locks: Enum.map(results, & &1.lock),
         runtimes: Enum.map(results, & &1.runtime),
         deferred_count: Enum.sum(Enum.map(results, & &1.deferred_count))
       }}
    end
  end

  @spec build(map(), map(), map(), map(), module(), keyword()) ::
          {:ok, %{lock: map(), runtime: map(), deferred_count: non_neg_integer()}}
          | {:error, [String.t()]}
  def build(manifest, extract, lock, runtime, backend, opts \\ []) do
    reason = Keyword.get(opts, :reason)
    link = Keyword.get(opts, :link)
    langs = backend.__translatable_runtime__(:langs)

    manifest_messages = Artifact.index_messages(manifest["messages"])
    extract_messages = Artifact.index_messages(extract["messages"])
    lock_messages = Artifact.index_messages(lock["messages"])
    runtime_messages = Artifact.index_messages(runtime["messages"])
    existing_deferred = Artifact.index_messages(lock["deferred"])

    pending =
      manifest_messages
      |> Enum.filter(fn {key, message} ->
        pending_lock?(message, Map.get(lock_messages, key)) or
          pending_runtime?(key, langs, runtime_messages)
      end)

    missing_extract =
      pending
      |> Enum.map(fn {key, _message} -> key end)
      |> Enum.reject(&Map.has_key?(extract_messages, &1))

    if missing_extract != [] do
      {:error, Enum.map(missing_extract, &"#{&1} is missing from the full extract bundle")}
    else
      pending_deferred =
        Map.new(pending, fn {key, message} ->
          {key, deferred_message(message, langs, reason, link)}
        end)

      deferred =
        existing_deferred
        |> Map.merge(pending_deferred)
        |> Artifact.sort_message_map()

      runtime_messages =
        Enum.reduce(pending, runtime_messages, fn {key, _message}, acc ->
          extract_message = Map.fetch!(extract_messages, key)
          Map.put(acc, key, runtime_fallback_message(extract_message, langs))
        end)

      lock =
        lock
        |> Map.put("deferred", deferred)
        |> remove_empty_deferred()

      runtime =
        runtime
        |> Map.put("format", "translatable.runtime.v1")
        |> Map.put("messages", Artifact.sort_message_map(runtime_messages))

      {:ok, %{lock: lock, runtime: runtime, deferred_count: length(pending)}}
    end
  end

  defp write_shards(app, backend, source_shards, runtime_shards, opts) do
    source_shards
    |> Enum.zip(runtime_shards)
    |> Enum.reduce_while({:ok, []}, fn {source_shard, runtime_shard}, {:ok, acc} ->
      manifest_path = Keyword.get(opts, :manifest_path, source_shard.manifest_path)
      extract_path = Keyword.get(opts, :extract_path, source_shard.extract_path)
      lock_path = Keyword.get(opts, :lock_path, runtime_shard.lock_path)
      runtime_path = Keyword.get(opts, :runtime_path, runtime_shard.runtime_path)

      with :ok <- require_current_manifest(app, source_shard.modules, manifest_path),
           {:ok, manifest} <- read_json(manifest_path, "Source manifest"),
           {:ok, extract} <- read_json(extract_path, "Full extract"),
           {:ok, lock} <- read_json(lock_path, "Lock"),
           {:ok, runtime} <- read_json(runtime_path, "Runtime bundle"),
           {:ok, result} <- build(manifest, extract, lock, runtime, backend, opts) do
        Artifact.write_json!(lock_path, result.lock)
        Artifact.write_json!(runtime_path, result.runtime)

        written = %{
          lock: lock_path,
          runtime: runtime_path,
          deferred_count: result.deferred_count
        }

        {:cont, {:ok, [written | acc]}}
      else
        {:error, _errors} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, _errors} = error -> error
    end
  end

  defp require_current_manifest(app, modules, manifest_path) do
    current = Extract.build(modules, app: app).manifest

    with {:ok, manifest} <- read_json(manifest_path, "Source manifest") do
      current_index = Artifact.index_messages(current["messages"])
      manifest_index = Artifact.index_messages(manifest["messages"])

      stale_key =
        Enum.find_value(current_index, fn {key, current_message} ->
          case Map.fetch(manifest_index, key) do
            {:ok, saved_message} ->
              if Artifact.first_stale_hash(current_message, saved_message), do: key

            :error ->
              key
          end
        end)

      if stale_key do
        {:error,
         ["Source manifest is not current for #{stale_key}; run mix translatable.extract first"]}
      else
        :ok
      end
    end
  end

  defp read_json(path, label) do
    case Artifact.read_json(path) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, :enoent} ->
        {:error, ["#{label} not found: #{path}"]}

      {:error, %Jason.DecodeError{} = reason} ->
        {:error, ["Invalid JSON in #{path}: #{Exception.message(reason)}"]}

      {:error, reason} ->
        {:error, ["Unable to read #{path}: #{inspect(reason)}"]}
    end
  end

  defp pending_lock?(_message, nil), do: true

  defp pending_lock?(message, lock_message) do
    Artifact.first_stale_hash(message, lock_message) != nil
  end

  defp pending_runtime?(key, langs, runtime_messages) do
    case Map.fetch(runtime_messages, key) do
      {:ok, translations} when is_map(translations) ->
        Enum.any?(langs, &(not is_binary(translations[&1])))

      _other ->
        true
    end
  end

  defp deferred_message(message, langs, reason, link) do
    %{
      "source_hash" => message["source_hash"],
      "params_hash" => message["params_hash"],
      "definition_hash" => message["definition_hash"],
      "langs" => langs
    }
    |> maybe_put("reason", reason)
    |> maybe_put("link", link)
  end

  defp runtime_fallback_message(extract_message, langs) do
    langs
    |> Enum.reduce(%{}, fn lang, acc -> Map.put(acc, lang, extract_message["source"]) end)
    |> Artifact.sort_message_map()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp remove_empty_deferred(%{"deferred" => deferred} = lock) when deferred == %{},
    do: Map.delete(lock, "deferred")

  defp remove_empty_deferred(lock), do: lock
end
