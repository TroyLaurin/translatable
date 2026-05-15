defmodule Translatable.Runtime do
  @moduledoc """
  Runtime translation API and configuration DSL.

  A runtime backend defines how messages are translated in an application. Most
  projects should have one backend module, conventionally named something like
  `MyApp.IsTranslatable`:

      defmodule MyApp.IsTranslatable do
        use Translatable.Runtime

        source_lang "en"
        langs ["en", "es", "de"]

        fallback "es-MX", to: ["es", "en"]

        bundle_everything filename: "my_app"

        provider Translatable.Provider.Json
        provider Translatable.Provider.Source
      end

  The generated backend exposes `translate/2` and `translate!/2`:

      MyApp.IsTranslatable.translate(Messages.greeting("Troy"), to: "es")

  Translation calls require an explicit target language through `:to`. Web
  applications can add a thin Plug or view helper layer on top, but the runtime
  engine remains explicit so it can be used safely outside a request process.

  ## Providers

  Providers are tried in order. If a provider knows about a message key, it owns
  all language variants for that key. Later providers are not mixed in for
  missing languages from the same message. This keeps migrations between backing
  stores deterministic.

  The common production setup is `Translatable.Provider.Json` followed by
  `Translatable.Provider.Source` in development or test. Production applications
  may omit the source provider once packaged runtime bundles include every
  required fallback string.

  ## Interpolation

  `Translatable.Interpolator.Simple` is the default and replaces `{name}` style
  placeholders. `cldr_backend/1` opts into `Translatable.Interpolator.Cldr` for
  ICU MessageFormat interpolation when the application has configured CLDR.

  ## Bundles

  Bundle configuration controls how extraction and packaging tasks split files.
  It does not affect message keys.

      bundle_everything filename: "my_app"
      bundle_per_module path: "my_app"

  For intentional groups, use `bundle_custom/2`:

      bundle_custom path: "my_app" do
        default filename: "my_app.json"

        bundle filename: "web.json",
          includes: submodules(of: MyAppWeb)

        bundle filename: "commands.json",
          includes: [
            submodules(of: MyApp.Game.Command),
            submodules(of: MyApp.Game.Continuation)
          ]
      end

  Custom bundle matchers use specificity. A module matching both
  `submodules(of: MyAppWeb)` and `submodules(of: MyAppWeb.BoardLive)` is routed
  to the latter because it names more module segments. Equal specificity ties
  and duplicate output filenames are configuration errors.
  """

  alias Translatable.Definition
  alias Translatable.Interpolator.Simple
  alias Translatable.Message
  alias Translatable.Provider.Cache, as: ProviderCache
  alias Translatable.Provider.Source

  @type provider_config() :: module() | {module(), keyword()}

  defmacro __using__(_opts) do
    quote do
      import Translatable.Runtime,
        only: [
          bundle_custom: 1,
          bundle_custom: 2,
          bundle_everything: 1,
          bundle_per_module: 1,
          bundle: 1,
          cldr_backend: 1,
          default: 1,
          fallback: 2,
          interpolate_with: 1,
          interpolate_with: 2,
          langs: 1,
          provider: 1,
          provider: 2,
          source_lang: 1,
          submodules: 1
        ]

      Module.register_attribute(__MODULE__, :translatable_runtime_providers,
        accumulate: true,
        persist: false
      )

      Module.register_attribute(__MODULE__, :translatable_runtime_fallbacks,
        accumulate: true,
        persist: false
      )

      @translatable_runtime_source_locale "en"
      @translatable_runtime_locales ["en"]
      @translatable_runtime_interpolator {Translatable.Interpolator.Simple, []}
      @translatable_runtime_bundle nil

      @before_compile Translatable.Runtime
    end
  end

  defmacro bundle_everything(opts) when is_list(opts) do
    bundle = Translatable.Bundle.everything(opts)

    quote bind_quoted: [bundle: Macro.escape(bundle)] do
      @translatable_runtime_bundle bundle
    end
  end

  defmacro bundle_per_module(opts) when is_list(opts) do
    bundle = Translatable.Bundle.per_module(opts)

    quote bind_quoted: [bundle: Macro.escape(bundle)] do
      @translatable_runtime_bundle bundle
    end
  end

  defmacro bundle_custom(opts \\ [], do: block) when is_list(opts) do
    rules = custom_bundle_rules(block, __CALLER__)
    bundle = Translatable.Bundle.custom(opts, rules)

    quote bind_quoted: [bundle: Macro.escape(bundle)] do
      @translatable_runtime_bundle bundle
    end
  end

  defmacro default(opts) when is_list(opts) do
    rule = Translatable.Bundle.default(opts)

    quote do
      unquote(Macro.escape(rule))
    end
  end

  defmacro bundle(opts) when is_list(opts) do
    opts =
      Keyword.update!(opts, :includes, fn includes ->
        includes
        |> List.wrap()
        |> Enum.map(&custom_bundle_matcher(&1, __CALLER__))
      end)

    rule = Translatable.Bundle.bundle(opts)

    quote do
      unquote(Macro.escape(rule))
    end
  end

  defmacro submodules(of: module) do
    matcher = Translatable.Bundle.submodules(of: Macro.expand(module, __CALLER__))

    quote do
      unquote(Macro.escape(matcher))
    end
  end

  defmacro provider(module, opts \\ []) when is_list(opts) do
    module = Macro.expand(module, __CALLER__)

    quote bind_quoted: [module: module, opts: opts] do
      @translatable_runtime_providers {module, opts}
    end
  end

  defmacro source_lang(lang) when is_binary(lang) do
    quote bind_quoted: [lang: lang] do
      @translatable_runtime_source_locale lang
    end
  end

  defmacro langs(langs) when is_list(langs) do
    validate_fallbacks!(langs)
    warn_duplicate_langs(langs)

    quote bind_quoted: [langs: langs] do
      @translatable_runtime_locales langs
    end
  end

  defmacro fallback(lang, to: fallbacks) when is_binary(lang) and is_list(fallbacks) do
    validate_fallbacks!(fallbacks)
    warn_duplicate_fallbacks(lang, fallbacks)

    quote bind_quoted: [lang: lang, fallbacks: fallbacks] do
      @translatable_runtime_fallbacks {lang, fallbacks}
    end
  end

  defmacro fallback(_locale, _opts) do
    raise ArgumentError, "fallback/2 expects a binary lang and a :to list"
  end

  defmacro cldr_backend(module) do
    module = Macro.expand(module, __CALLER__)

    quote bind_quoted: [module: module] do
      @translatable_runtime_interpolator {Translatable.Interpolator.Cldr, [backend: module]}
    end
  end

  defmacro interpolate_with(module, opts \\ []) when is_list(opts) do
    module = Macro.expand(module, __CALLER__)

    quote bind_quoted: [module: module, opts: opts] do
      @translatable_runtime_interpolator {module, opts}
    end
  end

  defmacro __before_compile__(env) do
    providers =
      env.module
      |> Module.get_attribute(:translatable_runtime_providers)
      |> Enum.reverse()
      |> case do
        [] -> [{Source, []}]
        providers -> providers
      end

    fallbacks =
      env.module
      |> Module.get_attribute(:translatable_runtime_fallbacks)
      |> Enum.reverse()
      |> Map.new()

    source_locale = Module.get_attribute(env.module, :translatable_runtime_source_locale)
    locales = Module.get_attribute(env.module, :translatable_runtime_locales)
    interpolator = Module.get_attribute(env.module, :translatable_runtime_interpolator)
    bundle = Module.get_attribute(env.module, :translatable_runtime_bundle)

    quote do
      def translate(message, opts \\ []) do
        opts =
          opts
          |> Keyword.put_new(:runtime, __MODULE__)
          |> Keyword.put_new(:providers, unquote(Macro.escape(providers)))
          |> Keyword.put_new(:fallbacks, unquote(Macro.escape(fallbacks)))
          |> Keyword.put_new(:interpolator, unquote(Macro.escape(interpolator)))

        Translatable.Runtime.translate(message, opts)
      end

      def translate!(message, opts \\ []) do
        opts =
          opts
          |> Keyword.put_new(:runtime, __MODULE__)
          |> Keyword.put_new(:providers, unquote(Macro.escape(providers)))
          |> Keyword.put_new(:fallbacks, unquote(Macro.escape(fallbacks)))
          |> Keyword.put_new(:interpolator, unquote(Macro.escape(interpolator)))

        Translatable.Runtime.translate!(message, opts)
      end

      def __translatable_runtime__(:providers), do: unquote(Macro.escape(providers))
      def __translatable_runtime__(:fallbacks), do: unquote(Macro.escape(fallbacks))
      def __translatable_runtime__(:source_lang), do: unquote(source_locale)
      def __translatable_runtime__(:langs), do: unquote(locales)
      def __translatable_runtime__(:interpolator), do: unquote(Macro.escape(interpolator))
      def __translatable_runtime__(:bundle), do: unquote(Macro.escape(bundle))

      def reload_providers do
        Translatable.Runtime.reload_providers(__MODULE__, __translatable_runtime__(:providers))
      end

      def reload_provider(provider_module) do
        Translatable.Runtime.reload_provider(
          __MODULE__,
          provider_module,
          __translatable_runtime__(:providers)
        )
      end
    end
  end

  @spec reload_providers(module(), [provider_config()]) :: :ok | {:error, term()}
  def reload_providers(runtime, providers) do
    ProviderCache.reload(runtime, providers)
  end

  @spec reload_provider(module(), module(), [provider_config()]) :: :ok | {:error, term()}
  def reload_provider(runtime, provider_module, providers) do
    ProviderCache.reload(runtime, provider_module, providers)
  end

  @spec prepare_providers(module(), [provider_config()]) :: :ok | {:error, term()}
  def prepare_providers(runtime, providers) do
    providers
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {provider, index}, :ok ->
      case ProviderCache.instance(runtime, index, provider) do
        {:ok, _instance} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec validate_interpolation(String.t(), map(), {module(), keyword()}) ::
          :ok | {:error, [String.t()]}
  def validate_interpolation(text, params, {module, opts}) do
    Translatable.Interpolator.validate_message(module, text, params, opts)
  end

  @spec translate(Message.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def translate(%Message{} = message, opts) do
    with {:ok, lang} <- fetch_lang(opts),
         {:ok, definition} <- definition(message),
         {:ok, bindings} <- resolve_bindings(message.bindings, opts),
         {:ok, text, matched_lang} <- message_text(definition, lang, opts),
         {:ok, rendered} <- interpolate(text, bindings, matched_lang, opts) do
      {:ok, rendered}
    end
  end

  @spec translate!(Message.t(), keyword()) :: String.t()
  def translate!(%Message{} = message, opts) do
    case translate(message, opts) do
      {:ok, rendered} -> rendered
      {:error, reason} -> raise ArgumentError, "unable to translate message: #{inspect(reason)}"
    end
  end

  defp fetch_lang(opts) do
    case Keyword.fetch(opts, :to) do
      {:ok, lang} when is_binary(lang) -> {:ok, lang}
      {:ok, lang} -> {:error, {:invalid_lang, lang}}
      :error -> fetch_lang_option(opts)
    end
  end

  defp fetch_lang_option(opts) do
    case Keyword.fetch(opts, :lang) do
      {:ok, lang} when is_binary(lang) -> {:ok, lang}
      {:ok, lang} -> {:error, {:invalid_lang, lang}}
      :error -> {:error, :missing_lang}
    end
  end

  defp definition(%Message{module: module, name: name}) do
    case module.__translatable__({:definition, name}) do
      {:ok, %Definition{}} = ok -> ok
      :error -> {:error, {:unknown_message, module, name}}
      other -> {:error, {:invalid_translatable_callback, module, other}}
    end
  rescue
    exception in UndefinedFunctionError ->
      case exception do
        %UndefinedFunctionError{module: ^module, function: :__translatable__, arity: 1} ->
          {:error, {:module_not_translatable, module}}

        _other ->
          reraise exception, __STACKTRACE__
      end
  end

  defp lookup(%Definition{} = definition, lang, opts) do
    providers = Keyword.get(opts, :providers, [{Source, []}])
    fallbacks = Keyword.get(opts, :fallbacks, %{})
    runtime = Keyword.get(opts, :runtime)

    lookup_provider_chain(
      Enum.with_index(providers),
      runtime,
      definition,
      fallback_langs(lang, fallbacks, definition.source_locale)
    )
  end

  defp message_text(%Definition{translatable?: false, source: source}, lang, _opts) do
    {:ok, source, lang}
  end

  defp message_text(%Definition{} = definition, lang, opts) do
    lookup(definition, lang, opts)
  end

  defp lookup_provider_chain([], _runtime, definition, _langs) do
    {:error, {:missing_translation, Definition.external_key(definition)}}
  end

  defp lookup_provider_chain([{provider, index} | rest], runtime, definition, langs) do
    case lookup_provider(provider, index, runtime, definition, langs) do
      {:ok, text, lang} -> {:ok, text, lang}
      :unknown -> lookup_provider_chain(rest, runtime, definition, langs)
      :missing -> {:error, {:missing_translation, Definition.external_key(definition)}}
      {:error, _reason} = error -> error
    end
  end

  defp lookup_provider(provider, index, runtime, definition, langs) do
    with {:ok, instance} <- ProviderCache.instance(runtime, index, provider) do
      langs
      |> Enum.reduce_while(:unknown, fn lang, status ->
        case instance.module.lookup(definition, lang, instance.state) do
          {:ok, text} when is_binary(text) -> {:halt, {:ok, text, lang}}
          :unknown -> {:cont, status}
          :missing -> {:cont, :missing}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp fallback_langs(lang, fallbacks, source_lang) do
    langs = [lang | Map.get(fallbacks, lang, [])]

    if source_lang in langs do
      langs
    else
      langs ++ [source_lang]
    end
  end

  defp resolve_bindings(bindings, opts) when is_map(bindings) do
    bindings
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case resolve_value(value, opts) do
        {:ok, resolved} -> {:cont, {:ok, Map.put(acc, key, resolved)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp resolve_value(%Message{} = message, opts), do: translate(message, opts)

  defp resolve_value(values, opts) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case resolve_value(value, opts) do
        {:ok, resolved} -> {:cont, {:ok, [resolved | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp resolve_value(value, _opts), do: {:ok, value}

  defp interpolate(text, bindings, lang, opts) do
    {module, interpolator_opts} = Keyword.get(opts, :interpolator, {Simple, []})

    module.interpolate(text, bindings, lang, interpolator_opts)
  end

  defp validate_fallbacks!(fallbacks) do
    unless Enum.all?(fallbacks, &is_binary/1) do
      raise ArgumentError, "fallback/2 expects :to to be a list of binary langs"
    end
  end

  defp custom_bundle_rules(block, caller) do
    block
    |> block_expressions()
    |> Enum.map(fn expression ->
      expression
      |> expand_custom_bundle_directive(caller)
      |> custom_bundle_rule!()
    end)
  end

  defp block_expressions({:__block__, _meta, expressions}), do: expressions
  defp block_expressions(expression), do: [expression]

  defp expand_custom_bundle_directive({name, _meta, _args} = expression, caller)
       when name in [:default, :bundle] do
    expanded = Macro.expand(expression, caller)
    {value, _binding} = Code.eval_quoted(expanded, [], caller)
    value
  end

  defp expand_custom_bundle_directive(other, _caller) do
    raise ArgumentError, "unsupported bundle_custom directive: #{Macro.to_string(other)}"
  end

  defp custom_bundle_rule!(%Translatable.Bundle.CustomRule{} = rule), do: rule

  defp custom_bundle_rule!(other) do
    raise ArgumentError, "unsupported bundle_custom directive: #{inspect(other)}"
  end

  defp custom_bundle_matcher({:submodules, _meta, [[of: module_ast]]}, caller) do
    Translatable.Bundle.submodules(of: Macro.expand(module_ast, caller))
  end

  defp custom_bundle_matcher({:__aliases__, _meta, _segments} = module_ast, caller) do
    module = Macro.expand(module_ast, caller)

    %Translatable.Bundle.Matcher.Exact{
      module: module,
      score: 1_000 + length(Module.split(module))
    }
  end

  defp custom_bundle_matcher(module, _caller) when is_atom(module) do
    %Translatable.Bundle.Matcher.Exact{
      module: module,
      score: 1_000 + length(Module.split(module))
    }
  end

  defp custom_bundle_matcher(other, _caller) do
    raise ArgumentError, "unsupported bundle_custom matcher: #{Macro.to_string(other)}"
  end

  defp warn_duplicate_fallbacks(lang, fallbacks) do
    fallbacks
    |> duplicate_values()
    |> Enum.each(fn duplicate ->
      IO.warn(
        "Translatable fallback #{inspect(lang)} includes duplicate lang #{inspect(duplicate)}"
      )
    end)
  end

  defp warn_duplicate_langs(langs) do
    langs
    |> duplicate_values()
    |> Enum.each(fn duplicate ->
      IO.warn("Translatable runtime lang list includes duplicate lang #{inspect(duplicate)}")
    end)
  end

  defp duplicate_values(values) do
    values
    |> Enum.reduce({MapSet.new(), MapSet.new()}, fn value, {seen, duplicates} ->
      if MapSet.member?(seen, value) do
        {seen, MapSet.put(duplicates, value)}
      else
        {MapSet.put(seen, value), duplicates}
      end
    end)
    |> elem(1)
    |> MapSet.to_list()
  end
end
