defmodule Translatable.InvalidMessageError do
  @moduledoc """
  Raised when calling a message whose definition was compiled with validation errors.
  """

  defexception [:module, :name, :errors]

  @impl Exception
  def message(%__MODULE__{module: module, name: name, errors: errors}) do
    details =
      errors
      |> List.wrap()
      |> Enum.join("; ")

    "translatable message #{inspect(module)}.#{name} is invalid: #{details}"
  end
end
