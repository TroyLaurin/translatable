defmodule Translatable.Plug.LanguageCode do
  @moduledoc false

  require Logger

  import Plug.Conn

  def init(opts) do
    backend = Keyword.fetch!(opts, :backend)

    %{
      backend: backend,
      default: Keyword.get(opts, :default, backend.__translatable_runtime__(:source_lang)),
      allowed: Keyword.get(opts, :allowed, backend.__translatable_runtime__(:langs)),
      assign: Keyword.get(opts, :assign, :translatable_lang)
    }
  end

  def put_lang(conn, lang, opts, source) do
    lang = normalize_lang(lang, opts, source)
    assign(conn, opts.assign, lang)
  end

  def current_lang(conn, opts) do
    Map.get(conn.assigns, opts.assign, opts.default)
  end

  def normalize_lang(lang, %{allowed: nil}, _source)
      when is_binary(lang) and lang != "" do
    lang
  end

  def normalize_lang(lang, %{allowed: allowed, default: default}, source)
      when is_binary(lang) and lang != "" do
    if lang in allowed do
      lang
    else
      Logger.warning(
        "Translatable ignored unrecognised language #{inspect(lang)} from #{source}; using #{inspect(default)}"
      )

      default
    end
  end

  def normalize_lang(_lang, %{default: default}, _source), do: default
end
