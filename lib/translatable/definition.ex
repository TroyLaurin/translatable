defmodule Translatable.Definition do
  @moduledoc """
  Compile-time definition data for a translatable message.

  Definitions are produced by `Translatable.defmsg/2` and exposed through a
  message module's `__translatable__/1` callback. They contain the source text,
  source language, translator notes, parameter contracts, pre-existing
  translations, and validation state for a message.

  Definitions are build-time metadata. Runtime values should carry
  `Translatable.Message` tokens rather than full definitions or rendered source
  strings.
  """

  alias Translatable.Param

  @type locale_name() :: String.t()
  @type key() :: {module(), atom()}

  @enforce_keys [:application, :module, :name, :arity, :source_locale, :source]
  defstruct [
    :application,
    :module,
    :name,
    :arity,
    :source_locale,
    :source,
    params: %{},
    translator_note: nil,
    translations: %{},
    translatable?: true,
    location: nil,
    warnings: [],
    errors: [],
    valid?: true
  ]

  @type t() :: %__MODULE__{
          application: atom(),
          module: module(),
          name: atom(),
          arity: non_neg_integer(),
          source_locale: locale_name(),
          source: String.t(),
          params: %{atom() => Param.t()},
          translator_note: String.t() | nil,
          translations: %{locale_name() => String.t()},
          translatable?: boolean(),
          location: {Path.t(), pos_integer()} | nil,
          warnings: [String.t()],
          errors: [String.t()],
          valid?: boolean()
        }

  @spec key(t()) :: key()
  def key(%__MODULE__{module: module, name: name}), do: {module, name}

  @spec external_key(t()) :: String.t()
  def external_key(%__MODULE__{application: application, module: module, name: name}) do
    module_name =
      module
      |> Atom.to_string()
      |> String.trim_leading("Elixir.")

    "#{application}:#{module_name}.#{name}"
  end
end
