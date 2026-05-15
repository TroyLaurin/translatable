defmodule Translatable.Provider.Cache do
  @moduledoc """
  ETS-backed cache for prepared provider instances.
  """

  alias Translatable.Provider
  alias Translatable.Provider.Instance

  @table __MODULE__

  @type provider_config() :: module() | {module(), keyword()}

  @spec instance(module() | nil, non_neg_integer(), provider_config()) ::
          {:ok, Instance.t()} | {:error, term()}
  def instance(runtime, index, provider_config) do
    ensure_table()

    key = key(runtime, index, provider_config)

    case :ets.lookup(@table, key) do
      [{^key, %Instance{} = instance}] ->
        {:ok, instance}

      [] ->
        prepare(runtime, index, provider_config, key)
    end
  end

  @spec reload(module(), [provider_config()]) :: :ok | {:error, term()}
  def reload(runtime, provider_configs) when is_atom(runtime) and is_list(provider_configs) do
    ensure_table()

    provider_configs
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {provider_config, index}, :ok ->
      case reload_provider(runtime, index, provider_config) do
        {:ok, _instance} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec reload(module(), module(), [provider_config()]) :: :ok | {:error, term()}
  def reload(runtime, provider_module, provider_configs)
      when is_atom(runtime) and is_atom(provider_module) and is_list(provider_configs) do
    ensure_table()

    provider_configs
    |> Enum.with_index()
    |> Enum.filter(fn {provider_config, _index} ->
      {module, _opts} = normalize(provider_config)
      module == provider_module
    end)
    |> Enum.reduce_while(:ok, fn {provider_config, index}, :ok ->
      case reload_provider(runtime, index, provider_config) do
        {:ok, _instance} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp prepare(runtime, index, provider_config, key) do
    {module, opts} = provider(runtime, provider_config)

    with {:ok, state} <- Provider.prepare(module, opts) do
      instance = %Instance{
        runtime: runtime,
        index: index,
        module: module,
        opts: opts,
        state: state
      }

      :ets.insert(@table, {key, instance})
      {:ok, instance}
    end
  end

  defp reload_provider(runtime, index, provider_config) do
    key = key(runtime, index, provider_config)
    {module, opts} = provider(runtime, provider_config)

    state =
      case :ets.lookup(@table, key) do
        [{^key, %Instance{state: state}}] -> state
        [] -> opts
      end

    with {:ok, new_state} <- Provider.reload(module, state, opts) do
      instance = %Instance{
        runtime: runtime,
        index: index,
        module: module,
        opts: opts,
        state: new_state
      }

      :ets.insert(@table, {key, instance})
      {:ok, instance}
    end
  end

  defp normalize({module, opts}), do: {module, opts}
  defp normalize(module) when is_atom(module), do: {module, []}

  defp provider(runtime, provider_config) do
    {module, opts} = normalize(provider_config)
    {module, Keyword.put_new(opts, :backend, runtime)}
  end

  defp key(runtime, index, provider_config) do
    {module, opts} = provider(runtime, provider_config)
    {runtime, index, module, opts}
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, read_concurrency: true])
        rescue
          ArgumentError -> @table
        end

      table ->
        table
    end
  end
end
