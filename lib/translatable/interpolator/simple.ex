defmodule Translatable.Interpolator.Simple do
  @moduledoc """
  Minimal interpolation for `{name}` placeholders.

  This interpolator intentionally does not implement ICU formatting. It exists
  as the dependency-free baseline for applications that do not need locale-aware
  number, date, plural, or select formatting.
  """

  @behaviour Translatable.Interpolator

  @impl Translatable.Interpolator
  def interpolate(text, bindings, _locale, _opts) when is_binary(text) and is_map(bindings) do
    rendered =
      Regex.replace(~r/{\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*}/, text, fn _match, key ->
        bindings
        |> binding_value(key)
        |> to_string()
      end)

    {:ok, rendered}
  end

  @impl Translatable.Interpolator
  def validate_message(text, params, _opts) when is_binary(text) and is_map(params) do
    referenced_names =
      ~r/{\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*}/
      |> Regex.scan(text, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    validate_references(referenced_names, params)
  end

  defp binding_value(bindings, key) do
    Enum.find_value(bindings, "{#{key}}", fn
      {binding_key, value} when is_atom(binding_key) ->
        if Atom.to_string(binding_key) == key, do: value

      {binding_key, value} when is_binary(binding_key) ->
        if binding_key == key, do: value

      _binding ->
        nil
    end)
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
