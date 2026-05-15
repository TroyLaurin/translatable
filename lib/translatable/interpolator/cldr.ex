defmodule Translatable.Interpolator.Cldr do
  @moduledoc """
  ICU message interpolation backed by `ex_cldr_messages`.

  Configure with `backend: MyApp.Cldr`. The CLDR dependencies can remain
  optional when Translatable is extracted; this module returns structured errors
  if the required CLDR modules are not available.
  """

  @behaviour Translatable.Interpolator

  @impl Translatable.Interpolator
  def interpolate(text, bindings, locale, opts) when is_binary(text) and is_map(bindings) do
    with {:ok, backend} <- fetch_backend(opts),
         :ok <- ensure_cldr_messages() do
      apply(Cldr.Message, :format, [text, bindings, [backend: backend, locale: locale]])
    end
  end

  @impl Translatable.Interpolator
  def validate_message(text, params, _opts) when is_binary(text) and is_map(params) do
    with :ok <- ensure_cldr_messages(),
         {:ok, referenced_names} <- referenced_names(text) do
      validate_references(referenced_names, params)
    else
      {:error, reason} -> {:error, ["invalid ICU message: #{inspect(reason)}"]}
    end
  end

  defp fetch_backend(opts) do
    case Keyword.fetch(opts, :backend) do
      {:ok, backend} when is_atom(backend) -> {:ok, backend}
      {:ok, backend} -> {:error, {:invalid_cldr_backend, backend}}
      :error -> {:error, :missing_cldr_backend}
    end
  end

  defp ensure_cldr_messages do
    if Code.ensure_loaded?(Cldr.Message) do
      :ok
    else
      {:error, :cldr_messages_not_available}
    end
  end

  defp referenced_names(text) do
    case apply(Cldr.Message, :bindings, [text]) do
      bindings when is_list(bindings) ->
        {:ok, bindings |> List.flatten() |> Enum.map(&to_string/1) |> Enum.uniq()}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp validate_references(referenced_names, params) do
    declared = Map.keys(params)
    declared_names = Enum.map(declared, &Atom.to_string/1)
    undeclared_names = referenced_names -- declared_names
    missing_references = Enum.reject(declared, &(Atom.to_string(&1) in referenced_names))

    errors =
      Enum.map(undeclared_names, &"references undeclared parameter :#{&1}") ++
        Enum.map(missing_references, &"does not reference declared parameter #{inspect(&1)}")

    if errors == [], do: :ok, else: {:error, errors}
  end
end
