defmodule Translatable.Plug.SessionLanguage do
  @moduledoc """
  Assigns a language code from the session.
  """

  import Plug.Conn

  alias Translatable.Plug.LanguageCode

  @behaviour Plug

  @impl Plug
  def init(opts) do
    opts
    |> LanguageCode.init()
    |> Map.put(:session_key, Keyword.get(opts, :session_key, :translatable_lang))
  end

  @impl Plug
  def call(conn, opts) do
    lang = get_session(conn, opts.session_key)
    LanguageCode.put_lang(conn, lang, opts, "session")
  end
end
