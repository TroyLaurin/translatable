defmodule Translatable.Validate.Reporter.Issue do
  @moduledoc """
  Public validation issue shape emitted by `Translatable.Validate.Reporter`.

  This struct is intentionally separate from `Translatable.Validation.Issue`,
  which is the validator's internal representation. Reporter output is a public
  API and should remain stable even if validation internals change.
  """

  @enforce_keys [:severity, :code, :problem, :fix]
  defstruct [:severity, :code, :problem, :fix, message: nil, context: %{}, languages: []]

  @type severity() :: :error | :warning

  @type t() :: %__MODULE__{
          severity: severity(),
          code: atom(),
          problem: String.t(),
          fix: String.t(),
          message: String.t() | nil,
          context: map(),
          languages: [String.t()]
        }
end
