defmodule Translatable.RuntimeTest do
  use ExUnit.Case, async: true

  alias Translatable.Definition
  alias Translatable.Message
  alias Translatable.Provider.Source

  defmodule Messages do
    use Translatable

    translatable_source "en"

    defmsg hello(name) do
      param :name, :string, "The visible player name"
      source "Hello {name}"
      translated_to "es", "Hola {name}"
    end

    defmsg ready(count) do
      param :count, :number, "The number of ready players"
      source "Ready {count}"
      translated_to "es", "Preparado {count}"
    end

    defmsg brand() do
      dont_translate()
      source "Pendulum"
    end
  end

  defmodule MemoryProvider do
    @behaviour Translatable.Provider

    @impl Translatable.Provider
    def lookup(%Definition{name: :hello}, "fr", opts) do
      {:ok, Keyword.fetch!(opts, :hello)}
    end

    def lookup(%Definition{name: :hello}, _locale, _opts), do: :missing

    def lookup(_definition, _locale, _opts), do: :unknown
  end

  defmodule OwningMissingProvider do
    @behaviour Translatable.Provider

    @impl Translatable.Provider
    def lookup(%Definition{name: :ready}, _locale, _opts), do: :missing
    def lookup(_definition, _locale, _opts), do: :unknown
  end

  defmodule BrandProvider do
    @behaviour Translatable.Provider

    @impl Translatable.Provider
    def lookup(%Definition{name: :brand}, _locale, _opts), do: {:ok, "Pendulo"}
    def lookup(_definition, _locale, _opts), do: :unknown
  end

  defmodule Runtime do
    use Translatable.Runtime

    provider MemoryProvider, hello: "Bonjour {name}"
    provider Source

    fallback "fr-CA", to: ["fr", "es", "en"]
  end

  defmodule CldrRuntime do
    use Translatable.Runtime

    provider Source
    interpolate_with Translatable.Interpolator.Cldr, backend: TranslatableTest.Cldr
  end

  test "source provider renders source and pretranslated strings from module metadata" do
    assert {:ok, "Hello Troy"} =
             Translatable.Runtime.translate(Messages.hello("Troy"),
               to: "en",
               providers: [Source]
             )

    assert {:ok, "Hola Troy"} =
             Translatable.Runtime.translate(Messages.hello("Troy"),
               to: "es",
               providers: [Source]
             )
  end

  test "runtime modules use providers in order before falling back" do
    assert {:ok, "Bonjour Troy"} = Runtime.translate(Messages.hello("Troy"), to: "fr")
  end

  test "runtime modules apply lang fallback chains" do
    assert {:ok, "Bonjour Troy"} = Runtime.translate(Messages.hello("Troy"), to: "fr-CA")
    assert {:ok, "Preparado 3"} = Runtime.translate(Messages.ready(3), to: "fr-CA")
    assert {:ok, "Ready 3"} = Runtime.translate(Messages.ready(3), to: "de")
  end

  test "fallback declarations warn about duplicates at compile time" do
    warning =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule Translatable.RuntimeTest.DuplicateFallbackRuntime do
          use Translatable.Runtime

          fallback "de-AT", to: ["de", "de", "en"]
        end
        """)
      end)

    assert warning =~ ~s(Translatable fallback "de-AT" includes duplicate lang "de")
  end

  test "runtime modules expose their configured interpolator" do
    assert Runtime.__translatable_runtime__(:interpolator) ==
             {Translatable.Interpolator.Simple, []}

    assert CldrRuntime.__translatable_runtime__(:interpolator) ==
             {Translatable.Interpolator.Cldr, [backend: TranslatableTest.Cldr]}
  end

  test "runtime modules expose their configured bundle rule" do
    defmodule BundleRuntime do
      use Translatable.Runtime

      bundle_everything filename: "bundle_test", path: "demo"
    end

    assert %Translatable.Bundle{
             strategy: :everything,
             filename: "bundle_test",
             path: "demo"
           } = BundleRuntime.__translatable_runtime__(:bundle)
  end

  test "cldr interpolator supports ICU number formatting" do
    defmodule NumberMessages do
      use Translatable

      defmsg count(count) do
        param :count, :number, "A formatted number"
        source "Count {count, number}"
      end
    end

    assert {:ok, "Count 1,234"} = CldrRuntime.translate(NumberMessages.count(1234), to: "en")
  end

  test "cldr interpolator validates ICU number bindings" do
    params = %{
      count: %Translatable.Param{
        name: :count,
        type: :number,
        note: "A formatted number"
      }
    }

    assert :ok =
             Translatable.Runtime.validate_interpolation(
               "Count {count, number}",
               params,
               {Translatable.Interpolator.Cldr, backend: TranslatableTest.Cldr}
             )
  end

  test "an owning provider prevents language variants from later providers for the same key" do
    assert {:error, {:missing_translation, _key}} =
             Translatable.Runtime.translate(Messages.ready(3),
               to: "es",
               providers: [OwningMissingProvider, Source],
               fallbacks: %{"es" => ["en"]}
             )
  end

  test "not-translated messages render the source text without provider lookup" do
    assert {:ok, "Pendulum"} =
             Translatable.Runtime.translate(Messages.brand(),
               to: "es",
               providers: [BrandProvider, Source]
             )

    assert {:ok, definition} = Messages.__translatable__({:definition, :brand})
    refute definition.translatable?
  end

  test "json provider reads packaged translation files" do
    {:ok, definition} = Messages.__translatable__({:definition, :hello})
    key = Definition.external_key(definition)
    path = Path.join(System.tmp_dir!(), "translatable-runtime-json-test.json")

    File.write!(path, Jason.encode!(%{"messages" => %{key => %{"it" => "Ciao {name}"}}}))

    assert {:ok, "Ciao Troy"} =
             Translatable.Runtime.translate(Messages.hello("Troy"),
               to: "it",
               providers: [{Translatable.Provider.Json, files: [path]}]
             )
  end

  test "json provider keeps the earlier file when definitions overlap" do
    {:ok, definition} = Messages.__translatable__({:definition, :hello})
    key = Definition.external_key(definition)
    first_path = Path.join(System.tmp_dir!(), "translatable-runtime-json-first.json")
    second_path = Path.join(System.tmp_dir!(), "translatable-runtime-json-second.json")

    File.write!(first_path, Jason.encode!(%{"messages" => %{key => %{"it" => "Prima {name}"}}}))

    File.write!(
      second_path,
      Jason.encode!(%{"messages" => %{key => %{"it" => "Seconda {name}"}}})
    )

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:ok, "Prima Troy"} =
               Translatable.Runtime.translate(Messages.hello("Troy"),
                 to: "it",
                 providers: [{Translatable.Provider.Json, files: [first_path, second_path]}]
               )
    end)
    |> then(fn log ->
      assert log =~ "ignored duplicate message"
      assert log =~ key
    end)
  end

  test "json provider can derive files from the runtime backend bundle" do
    {:ok, definition} = Messages.__translatable__({:definition, :hello})
    key = Definition.external_key(definition)
    filename = "translatable-runtime-derived-json-test"

    path_prefix = "runtime_derived_json_test_#{System.unique_integer([:positive])}"
    on_exit(fn -> File.rm_rf!(Path.join(["priv", "translatable", "runtime", path_prefix])) end)

    path = Path.join(["priv", "translatable", "runtime", path_prefix, "#{filename}.json"])

    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, Jason.encode!(%{"messages" => %{key => %{"it" => "Ciao {name}"}}}))

    Code.compile_string("""
    defmodule Translatable.RuntimeTest.DerivedJsonRuntime do
      use Translatable.Runtime

      bundle_everything filename: #{inspect(filename)}, path: #{inspect(path_prefix)}

      provider Translatable.Provider.Json
    end
    """)

    assert {:ok, "Ciao Troy"} =
             apply(Translatable.RuntimeTest.DerivedJsonRuntime, :translate, [
               Messages.hello("Troy"),
               [to: "it"]
             ])
  end

  test "json provider derives per-module files from the runtime bundle manifest" do
    {:ok, definition} = Messages.__translatable__({:definition, :hello})
    key = Definition.external_key(definition)
    path_prefix = "runtime_per_module_json_test_#{System.unique_integer([:positive])}"
    on_exit(fn -> File.rm_rf!(Path.join(["priv", "translatable", "runtime", path_prefix])) end)
    bundle = Translatable.Bundle.per_module(path: path_prefix)
    [shard] = Translatable.Bundle.runtime_shards(bundle, [Messages])

    shard.runtime_path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(
      shard.runtime_path,
      Jason.encode!(%{"messages" => %{key => %{"it" => "Ciao {name}"}}})
    )

    Translatable.Bundle.write_runtime_manifests!(bundle, [shard])

    Code.compile_string("""
    defmodule Translatable.RuntimeTest.PerModuleDerivedJsonRuntime do
      use Translatable.Runtime

      bundle_per_module path: #{inspect(path_prefix)}

      provider Translatable.Provider.Json
    end
    """)

    assert {:ok, "Ciao Troy"} =
             apply(Translatable.RuntimeTest.PerModuleDerivedJsonRuntime, :translate, [
               Messages.hello("Troy"),
               [to: "it"]
             ])
  end

  test "runtime DSL supports custom bundle routing" do
    [{runtime, _bytecode}] =
      Code.compile_string("""
      defmodule Translatable.RuntimeTest.CustomBundleRuntime do
        use Translatable.Runtime

        bundle_custom path: "custom_runtime_test" do
          default filename: "default.json"
          bundle filename: "messages.json", includes: submodules(of: Translatable.RuntimeTest.Messages)
        end
      end
      """)

    bundle = runtime.__translatable_runtime__(:bundle)
    [shard] = Translatable.Bundle.runtime_shards(bundle, [Messages])

    assert shard.id == "custom_runtime_test/messages"
    assert shard.runtime_path == "priv/translatable/runtime/custom_runtime_test/messages.json"
  end

  test "runtime modules can reload prepared json provider state" do
    {:ok, definition} = Messages.__translatable__({:definition, :hello})
    key = Definition.external_key(definition)
    path = Path.join(System.tmp_dir!(), "translatable-runtime-json-reload.json")

    File.write!(path, Jason.encode!(%{"messages" => %{key => %{"it" => "Prima {name}"}}}))

    defmodule JsonRuntime do
      use Translatable.Runtime

      provider(Translatable.Provider.Json,
        files: [Path.join(System.tmp_dir!(), "translatable-runtime-json-reload.json")]
      )
    end

    assert {:ok, "Prima Troy"} = JsonRuntime.translate(Messages.hello("Troy"), to: "it")

    File.write!(path, Jason.encode!(%{"messages" => %{key => %{"it" => "Dopo {name}"}}}))

    assert {:ok, "Prima Troy"} = JsonRuntime.translate(Messages.hello("Troy"), to: "it")
    assert :ok = JsonRuntime.reload_provider(Translatable.Provider.Json)
    assert {:ok, "Dopo Troy"} = JsonRuntime.translate(Messages.hello("Troy"), to: "it")
  end

  test "po provider reads raw gettext translation strings before interpolation" do
    path = Path.join(System.tmp_dir!(), "translatable-runtime-test.po")

    File.write!(path, """
    msgid "Hello {name}"
    msgstr "Hallo {name}"
    """)

    assert {:ok, "Hallo Troy"} =
             Translatable.Runtime.translate(Messages.hello("Troy"),
               to: "de",
               providers: [{Translatable.Provider.PO, path: path}]
             )
  end

  test "nested translatable message bindings render in the same lang" do
    defmodule NestedMessages do
      use Translatable

      defmsg name(name) do
        param :name, :string, "The visible name"
        source "{name}"
        translated_to "es", "{name} traducido"
      end

      defmsg hello(name) do
        param :name, :message, "A nested translated name"
        source "Hello {name}"
        translated_to "es", "Hola {name}"
      end
    end

    message = NestedMessages.hello(NestedMessages.name("Troy"))

    assert {:ok, "Hola Troy traducido"} =
             Translatable.Runtime.translate(message, to: "es", providers: [Source])
  end

  test "translate requires an explicit binary lang" do
    assert {:error, :missing_lang} = Translatable.Runtime.translate(Messages.hello("Troy"), [])

    assert {:error, {:invalid_lang, :es}} =
             Translatable.Runtime.translate(Messages.hello("Troy"), to: :es)
  end

  test "translate accepts lang as an explicit target option" do
    assert {:ok, "Hola Troy"} =
             Translatable.Runtime.translate(Messages.hello("Troy"),
               lang: "es",
               providers: [Source]
             )
  end

  test "translate falls back to the message source lang when no fallback is configured" do
    assert {:ok, "Hello Troy"} =
             Translatable.Runtime.translate(Messages.hello("Troy"),
               to: "de",
               providers: [Source]
             )
  end

  test "definition lookup calls the translatable callback directly" do
    message = %Message{
      application: :translatable,
      module: String,
      name: :not_a_message,
      bindings: %{}
    }

    assert {:error, {:module_not_translatable, String}} =
             Translatable.Runtime.translate(message, to: "en")
  end

  test "definition lookup reports unknown messages from translatable modules" do
    message = %Message{
      application: :translatable,
      module: Messages,
      name: :missing_message,
      bindings: %{}
    }

    assert {:error, {:unknown_message, Messages, :missing_message}} =
             Translatable.Runtime.translate(message, to: "en")
  end

  test "runtime failure reasons can be represented as translatable messages" do
    error_message =
      {:unknown_message, Messages, :missing_message}
      |> Translatable.Runtime.Error.message()

    assert %Message{
             application: :translatable,
             module: Translatable.Runtime.Messages,
             name: :unknown_message,
             bindings: %{module: module, name: name}
           } = error_message

    assert module =~ "Translatable.RuntimeTest.Messages"
    assert name == ":missing_message"

    assert {:ok, rendered} =
             Translatable.Runtime.translate(error_message,
               to: "en",
               providers: [Source]
             )

    assert rendered =~ "does not define the translatable message"
  end

  test "message keys include application, module, and local message name for exported bundles" do
    assert %Message{} = message = Messages.hello("Troy")
    assert message.application == :translatable

    assert {:ok, definition} = Messages.__translatable__({:definition, message.name})

    assert Definition.external_key(definition) =~
             "translatable:Translatable.RuntimeTest.Messages.hello"
  end
end
