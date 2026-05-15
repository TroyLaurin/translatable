defmodule Translatable.Provider.Gettext do
  @moduledoc """
  Alias provider for Gettext PO-file backed raw text lookup.

  This module exists so runtime configs can read naturally while still keeping
  the provider contract raw-text based.
  """

  @behaviour Translatable.Provider

  alias Translatable.Definition
  alias Translatable.Provider.PO

  @impl Translatable.Provider
  def lookup(%Definition{} = definition, locale, opts), do: PO.lookup(definition, locale, opts)
end
