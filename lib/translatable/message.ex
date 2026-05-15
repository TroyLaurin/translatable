defmodule Translatable.Message do
  @moduledoc """
  Persistable runtime reference to a translatable message.

  The message carries semantic identity and runtime bindings only. Source text,
  translator notes, pre-translated strings, and parameter contracts live in the
  defining module's `Translatable.Definition` data.

  This separation lets domain code and persistence layers stay language-neutral.
  A stored game event can keep a message token and render it later through a
  `Translatable.Runtime` backend for each viewer's chosen language.
  """

  @type locale_name() :: String.t()
  @type key() :: {module(), atom()}
  @type bindings() :: %{atom() => term()}

  @enforce_keys [:application, :module, :name, :bindings]
  defstruct [:application, :module, :name, :bindings]

  @type t() :: %__MODULE__{
          application: atom(),
          module: module(),
          name: atom(),
          bindings: bindings()
        }

  @spec key(t()) :: key()
  def key(%__MODULE__{module: module, name: name}), do: {module, name}
end
