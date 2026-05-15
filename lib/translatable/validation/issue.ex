defmodule Translatable.Validation.Issue do
  @moduledoc """
  Structured validation issue emitted by `Translatable.Validate`.
  """

  @enforce_keys [:severity, :code, :message]
  defstruct [:severity, :code, :message, context: %{}]

  @type severity() :: :error | :warning
  @type t() :: %__MODULE__{
          severity: severity(),
          code: atom(),
          message: String.t(),
          context: map()
        }
end
