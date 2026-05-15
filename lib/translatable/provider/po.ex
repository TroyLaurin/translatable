defmodule Translatable.Provider.PO do
  @moduledoc """
  Raw text provider backed by Gettext PO files.

  This provider reads PO files directly and returns untranslated raw message
  text. Configure with either `path: "..."` for a single PO file, or
  `priv: "priv/gettext", domain: "default"` for files at
  `LOCALE/LC_MESSAGES/DOMAIN.po`.
  """

  @behaviour Translatable.Provider

  alias Expo.Message
  alias Expo.PO
  alias Translatable.Definition

  @impl Translatable.Provider
  def prepare(opts), do: {:ok, opts}

  @impl Translatable.Provider
  def reload(opts), do: {:ok, opts}

  @impl Translatable.Provider
  def lookup(%Definition{source: source}, locale, opts) do
    with {:ok, path} <- path(locale, opts),
         {:ok, po} <- parse(path),
         {:ok, translation} <- lookup_message(po.messages, source) do
      {:ok, translation}
    else
      :missing -> :missing
      :unknown -> :unknown
      {:error, :enoent} -> :unknown
      {:error, _reason} = error -> error
    end
  end

  defp path(locale, opts) do
    case Keyword.fetch(opts, :path) do
      {:ok, path} when is_binary(path) ->
        {:ok, path}

      _ ->
        priv = Keyword.get(opts, :priv, "priv/gettext")
        domain = Keyword.get(opts, :domain, "default")
        {:ok, Path.join([priv, locale, "LC_MESSAGES", "#{domain}.po"])}
    end
  end

  defp parse(path) do
    PO.parse_file(path, strip_meta: true)
  end

  defp lookup_message(messages, source) do
    messages
    |> Enum.find_value(:unknown, fn
      %Message.Singular{obsolete: false, msgid: msgid, msgstr: msgstr} ->
        if IO.iodata_to_binary(msgid) == source do
          text = IO.iodata_to_binary(msgstr)
          if text == "", do: :missing, else: {:ok, text}
        end

      _message ->
        nil
    end)
  end
end
