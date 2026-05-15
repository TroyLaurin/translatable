defmodule Translatable.Param do
  @moduledoc """
  Parameter contract metadata for a translatable message.
  """

  @type kind() ::
          :string
          | :number
          | :integer
          | :boolean
          | :date
          | :time
          | :datetime
          | :message
          | {:select, [atom() | String.t()]}

  @enforce_keys [:name, :type, :note]
  defstruct [:name, :type, :note]

  @type t() :: %__MODULE__{
          name: atom(),
          type: kind(),
          note: String.t()
        }
end
