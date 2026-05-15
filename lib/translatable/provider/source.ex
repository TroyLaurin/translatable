defmodule Translatable.Provider.Source do
  @moduledoc """
  Provider backed by the source module metadata.

  It returns the source string for the definition source locale and any
  pre-translated strings declared with `translated_to/2`.
  """

  @behaviour Translatable.Provider

  alias Translatable.Definition

  @impl Translatable.Provider
  def lookup(%Definition{source_locale: locale, source: source}, locale, _opts), do: {:ok, source}

  def lookup(%Definition{translations: translations}, locale, _opts) do
    case Map.fetch(translations, locale) do
      {:ok, translation} -> {:ok, translation}
      :error -> :missing
    end
  end
end
