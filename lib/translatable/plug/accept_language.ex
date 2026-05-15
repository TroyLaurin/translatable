defmodule Translatable.Plug.AcceptLanguage do
  @moduledoc """
  Assigns a language code from the `accept-language` request header.
  """

  import Plug.Conn

  alias Translatable.Plug.LanguageCode

  @behaviour Plug

  @impl Plug
  def init(opts), do: LanguageCode.init(opts)

  @impl Plug
  def call(conn, opts) do
    lang =
      conn
      |> get_req_header("accept-language")
      |> List.first()
      |> preferred_lang(opts)

    LanguageCode.put_lang(conn, lang, opts, "accept-language")
  end

  defp preferred_lang(nil, opts), do: opts.default

  defp preferred_lang(header, %{allowed: allowed, default: default}) do
    header
    |> String.split(",")
    |> Enum.map(&parse_language_range/1)
    |> Enum.sort_by(fn {_code, quality} -> quality end, :desc)
    |> Enum.find_value(default, fn {code, _quality} ->
      cond do
        allowed == nil -> code
        code in allowed -> code
        base_lang(code) in allowed -> base_lang(code)
        true -> nil
      end
    end)
  end

  defp parse_language_range(range) do
    [code | params] =
      range
      |> String.trim()
      |> String.split(";")

    quality =
      Enum.find_value(params, 1.0, fn param ->
        case String.split(String.trim(param), "=", parts: 2) do
          ["q", value] ->
            case Float.parse(value) do
              {quality, ""} -> quality
              _ -> 1.0
            end

          _ ->
            nil
        end
      end)

    {code, quality}
  end

  defp base_lang(code) do
    code
    |> String.split("-", parts: 2)
    |> List.first()
  end
end
