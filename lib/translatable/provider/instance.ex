defmodule Translatable.Provider.Instance do
  @moduledoc """
  Prepared runtime state for one provider in a Translatable runtime module.
  """

  @enforce_keys [:runtime, :index, :module, :opts, :state]
  defstruct [:runtime, :index, :module, :opts, :state]

  @type t() :: %__MODULE__{
          runtime: module() | nil,
          index: non_neg_integer(),
          module: module(),
          opts: keyword(),
          state: term()
        }
end
