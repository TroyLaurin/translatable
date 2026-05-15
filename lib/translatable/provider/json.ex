defmodule Translatable.Provider.Json do
  @moduledoc """
  Raw text provider backed by packaged Translatable JSON files.

  The provider expects the exact bundle format produced by Translatable's
  packaging tasks:

      {
        "messages": {
          "pendulum:Pendulum.Messages.ready": {
            "es": "Preparado"
          }
        }
      }

  Configure with `files: ["priv/translatable.json"]`, or with no options to
  read from the runtime backend's configured bundle. For directory-based bundle
  strategies such as `bundle_per_module` and `bundle_custom`, the provider reads
  the generated runtime `manifest.json` and then loads the exact shard files
  listed there. This is release-safe and does not require Mix or source module
  discovery at runtime.

  Files are read and normalized during provider preparation and can be reloaded
  through the runtime module:

      MyApp.IsTranslatable.reload_provider(Translatable.Provider.Json)

  If duplicate message keys appear across files, the earlier configured file
  wins and a warning is logged. This keeps migration chains deterministic while
  still surfacing overlap mistakes during validation or development.

  Missing file handling is environment-sensitive by default: development and
  test ignore missing files so new strings can be developed without immediately
  packaging translations, while releases default to treating missing files as an
  error. Override with application config for `Translatable.Provider.Json` when
  needed.
  """

  require Logger

  @behaviour Translatable.Provider

  alias Translatable.Definition

  defstruct [:files, messages: %{}]

  @type t() :: %__MODULE__{files: [Path.t()], messages: map()}

  @impl Translatable.Provider
  def prepare(opts) do
    with {:ok, files} <- files(opts),
         {:ok, messages} <- load_files(files) do
      {:ok, %__MODULE__{files: files, messages: messages}}
    end
  end

  @impl Translatable.Provider
  def reload(%__MODULE__{files: files}) do
    prepare(files: files)
  end

  @impl Translatable.Provider
  def lookup(%Definition{} = definition, locale, %__MODULE__{messages: messages}) do
    key = Definition.external_key(definition)

    case Map.fetch(messages, key) do
      {:ok, locales} -> lookup_locale(locales, locale)
      :error -> :unknown
    end
  end

  defp lookup_locale(locales, locale) do
    case Map.fetch(locales, locale) do
      {:ok, translation} when is_binary(translation) -> {:ok, translation}
      {:ok, _invalid_translation} -> {:error, {:invalid_json_translation, locale}}
      :error -> :missing
    end
  end

  defp files(opts) do
    case Keyword.fetch(opts, :files) do
      {:ok, files} when is_list(files) and files != [] ->
        if Enum.all?(files, &is_binary/1) do
          {:ok, files}
        else
          {:error, :invalid_json_provider_files}
        end

      {:ok, _files} ->
        {:error, :invalid_json_provider_files}

      :error ->
        backend_files(opts)
    end
  end

  defp backend_files(opts) do
    case Keyword.fetch(opts, :backend) do
      {:ok, backend} when is_atom(backend) ->
        case backend.__translatable_runtime__(:bundle) do
          %Translatable.Bundle{} = bundle -> Translatable.Bundle.runtime_files(bundle)
          nil -> {:error, :missing_json_provider_bundle}
        end

      {:ok, _backend} ->
        {:error, :invalid_json_provider_backend}

      :error ->
        {:error, :missing_json_provider_files}
    end
  end

  defp load_files(files) do
    Enum.reduce_while(files, {:ok, %{}}, fn file, {:ok, acc} ->
      case load_file(file) do
        {:ok, messages} -> {:cont, {:ok, merge_messages(acc, messages, file)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp load_file(file) do
    with {:ok, body} <- File.read(file),
         {:ok, decoded} <- Jason.decode(body),
         {:ok, messages} <- fetch_messages(decoded) do
      {:ok, messages}
    else
      {:error, %Jason.DecodeError{} = reason} -> {:error, {:invalid_json_file, file, reason}}
      {:error, :enoent} -> missing_file(file)
      {:error, _reason} = error -> error
    end
  end

  defp fetch_messages(%{"messages" => messages}) when is_map(messages), do: {:ok, messages}
  defp fetch_messages(_decoded), do: {:error, :invalid_json_bundle}

  defp missing_file(file) do
    case missing_files_policy() do
      :ignore -> {:ok, %{}}
      :error -> {:error, {:missing_json_file, file}}
    end
  end

  defp missing_files_policy do
    :translatable
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get_lazy(:missing_files, &default_missing_files_policy/0)
  end

  defp default_missing_files_policy do
    if Code.ensure_loaded?(Mix) and Mix.env() in [:dev, :test] do
      :ignore
    else
      :error
    end
  end

  defp merge_messages(acc, messages, file) do
    Enum.reduce(messages, acc, fn {key, locales}, merged ->
      cond do
        not is_map(locales) ->
          Logger.warning(
            "Translatable JSON provider ignored invalid message entry #{inspect(key)} in #{file}"
          )

          merged

        Map.has_key?(merged, key) ->
          Logger.warning(
            "Translatable JSON provider ignored duplicate message #{inspect(key)} in #{file}"
          )

          merged

        true ->
          Map.put(merged, key, locales)
      end
    end)
  end
end
