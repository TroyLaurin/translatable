defmodule Translatable.Module do
  @moduledoc """
  Introspection data for a module that defines translatable messages.
  """

  alias Translatable.Definition

  @type locale_name() :: Definition.locale_name()

  @enforce_keys [:application, :module, :source_locale, :messages]
  defstruct [:application, :module, :source_locale, :messages]

  @type t() :: %__MODULE__{
          application: atom(),
          module: module(),
          source_locale: locale_name(),
          messages: [Definition.t()]
        }
end
