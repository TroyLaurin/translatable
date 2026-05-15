defmodule Translatable.Interpolator do
  @moduledoc """
  Behaviour for rendering raw translation text with resolved bindings.

  Interpolators are deliberately separate from providers. Providers find raw
  text for a message and language; interpolators render that text with runtime
  bindings.

  Applications that only need `{name}` placeholders can use
  `Translatable.Interpolator.Simple`. Applications that need ICU MessageFormat
  features can configure `Translatable.Interpolator.Cldr` through
  `Translatable.Runtime.cldr_backend/1`.

  The optional `validate_message/3` callback is used by
  `mix translatable.validate` to compare translated text with the declared
  parameter contract. Custom interpolation syntaxes should implement this
  callback so validation can catch malformed translated strings before release.
  """

  @type locale_name() :: String.t()
  @type bindings() :: %{(atom() | String.t()) => term()}
  @type opts() :: keyword()
  @type params() :: %{atom() => Translatable.Param.t()}

  @callback interpolate(String.t(), bindings(), locale_name(), opts()) ::
              {:ok, String.t()} | {:error, term()}

  @callback validate_message(String.t(), params(), opts()) :: :ok | {:error, [String.t()]}

  @optional_callbacks validate_message: 3

  @doc false
  @spec validate_message(module(), String.t(), params(), opts()) :: :ok | {:error, [String.t()]}
  def validate_message(module, text, params, opts) do
    Code.ensure_loaded?(module)

    if function_exported?(module, :validate_message, 3) do
      module.validate_message(text, params, opts)
    else
      :ok
    end
  end
end
