defmodule Translatable.Plug.GetLanguage do
  @moduledoc """
  Assigns a language code from a request parameter.
  """

  alias Translatable.Plug.LanguageCode

  @behaviour Plug

  @impl Plug
  def init(opts) do
    opts
    |> LanguageCode.init()
    |> Map.put(:param, Keyword.get(opts, :param, "lang"))
  end

  @impl Plug
  def call(conn, opts) do
    lang = Map.get(conn.params, opts.param)

    if is_binary(lang) and lang != "" do
      LanguageCode.put_lang(conn, lang, opts, "query parameter #{opts.param}")
    else
      conn
    end
  end
end
