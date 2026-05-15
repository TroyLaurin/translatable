defmodule Translatable.Artifact do
  @moduledoc """
  Shared helpers for Translatable JSON workflow artifacts.
  """

  @runtime_format "translatable.runtime.v1"
  @lock_format "translatable.lock.v1"

  @hash_fields ["source_hash", "params_hash", "definition_hash"]

  @spec hash_fields() :: [String.t()]
  def hash_fields, do: @hash_fields

  @spec read_json(Path.t()) :: {:ok, map()} | {:error, term()}
  def read_json(path) when is_binary(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body) do
      {:ok, decoded}
    end
  end

  @spec write_json!(Path.t(), map()) :: :ok
  def write_json!(path, data) when is_binary(path) and is_map(data) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(path, Jason.encode_to_iodata!(data, pretty: true))
  end

  @spec index_messages([map()] | map() | nil) :: map()
  def index_messages(messages) when is_list(messages), do: Map.new(messages, &{&1["key"], &1})
  def index_messages(messages) when is_map(messages), do: messages
  def index_messages(_messages), do: %{}

  @spec first_stale_hash(map(), map()) :: String.t() | nil
  def first_stale_hash(current_message, saved_message) do
    Enum.find(@hash_fields, &(current_message[&1] != saved_message[&1]))
  end

  @spec lock_message(map(), String.t(), [String.t()]) :: map()
  def lock_message(current, source_lang, packaged_langs) do
    %{
      "source_lang" => current["source_lang"],
      "source_hash" => current["source_hash"],
      "params_hash" => current["params_hash"],
      "definition_hash" => current["definition_hash"],
      "translatable" => current["translatable"],
      "langs" => lock_langs(current, source_lang, packaged_langs)
    }
  end

  @spec runtime_source_for_all_langs(map(), [String.t()]) :: map()
  def runtime_source_for_all_langs(current, packaged_langs) do
    packaged_langs
    |> Enum.reduce(%{}, fn lang, acc -> Map.put(acc, lang, current["source"]) end)
    |> sort_message_map()
  end

  @spec sort_message_map(map()) :: map()
  def sort_message_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Map.new()
  end

  @spec runtime_bundle(map()) :: map()
  def runtime_bundle(messages) do
    %{
      "format" => @runtime_format,
      "messages" => sort_message_map(messages)
    }
  end

  @spec lock_bundle(
          atom() | nil,
          module(),
          Translatable.Bundle.t() | nil,
          String.t(),
          [String.t()],
          map(),
          map()
        ) ::
          map()
  def lock_bundle(app, backend, bundle, source_lang, langs, messages, deferred \\ %{}) do
    %{
      "format" => @lock_format,
      "application" => app_name(app),
      "backend" => module_name(backend),
      "bundle" => bundle_to_json(bundle),
      "source_lang" => source_lang,
      "langs" => langs,
      "messages" => sort_message_map(messages)
    }
    |> put_deferred(deferred)
  end

  defp lock_langs(current, source_lang, packaged_langs) do
    packaged_langs
    |> Enum.reduce(%{}, fn lang, acc ->
      status =
        cond do
          lang == source_lang -> "source"
          current["translatable"] == false -> "dont_translate"
          true -> "translated"
        end

      Map.put(acc, lang, %{
        "status" => status,
        "source_hash" => current["source_hash"],
        "params_hash" => current["params_hash"]
      })
    end)
    |> sort_message_map()
  end

  defp put_deferred(lock, deferred) when deferred == %{}, do: lock
  defp put_deferred(lock, deferred), do: Map.put(lock, "deferred", sort_message_map(deferred))

  defp bundle_to_json(%Translatable.Bundle{} = bundle) do
    %{
      "strategy" => Atom.to_string(bundle.strategy),
      "path" => bundle.path,
      "filename" => bundle.filename
    }
  end

  defp bundle_to_json(nil), do: nil

  defp app_name(nil), do: nil
  defp app_name(app) when is_atom(app), do: Atom.to_string(app)

  defp module_name(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.trim_leading("Elixir.")
  end
end
