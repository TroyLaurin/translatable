defmodule Translatable.Provider do
  @moduledoc """
  Behaviour for raw translation text lookup providers.

  Providers answer whether they own a message definition and whether they have
  translation text for a locale. They do not interpolate bindings; interpolation
  belongs to the Translatable runtime.

  `:unknown` means the provider does not own the message key, so the runtime may
  try later providers. `:missing` means the provider owns the message key but has
  no translation for the requested locale, so the runtime may try locale
  fallbacks within the same provider but must not mix language variants for that
  key across later providers.
  """

  alias Translatable.Definition

  @type locale_name() :: String.t()
  @type opts() :: keyword()
  @type prepared() :: term()
  @type result() :: {:ok, String.t()} | :missing | :unknown | {:error, term()}

  @callback prepare(opts()) :: {:ok, prepared()} | {:error, term()}
  @callback reload(prepared()) :: {:ok, prepared()} | {:error, term()}
  @callback lookup(Definition.t(), locale_name(), prepared()) :: result()

  @optional_callbacks prepare: 1, reload: 1

  @doc false
  @spec prepare(module(), opts()) :: {:ok, prepared()} | {:error, term()}
  def prepare(module, opts) do
    Code.ensure_loaded?(module)

    if function_exported?(module, :prepare, 1) do
      module.prepare(opts)
    else
      {:ok, opts}
    end
  end

  @doc false
  @spec reload(module(), prepared(), opts()) :: {:ok, prepared()} | {:error, term()}
  def reload(module, prepared, opts) do
    Code.ensure_loaded?(module)

    if function_exported?(module, :reload, 1) do
      module.reload(prepared)
    else
      prepare(module, opts)
    end
  end
end
