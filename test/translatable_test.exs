defmodule TranslatableTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Translatable.Definition
  alias Translatable.InvalidMessageError
  alias Translatable.Message
  alias Translatable.Param

  defmodule Messages do
    use Translatable

    translatable_source "en"

    defmsg ready_self(total, ready) do
      translator_note "Shown while the game waits for every player to register as ready."
      param :total, :number, "The total number of players in the game"
      param :ready, :number, "The number of players who have already registered as ready"
      source "Ready ({ready, number} / {total, number})"
      translated_to "es", "Preparado ({ready, number} de {total, number})"
    end

    defmsg hello(name) do
      param :name, :string, "The visible player name"
      source "Hello {name}"
    end
  end

  test "defmsg creates a public function returning a persistable message reference" do
    assert %Message{
             application: :translatable,
             module: Messages,
             name: :ready_self,
             bindings: %{total: 4, ready: 2}
           } = Messages.ready_self(4, 2)
  end

  test "message definitions are available through behaviour introspection" do
    assert [:ready_self, :hello] = Messages.__translatable__(:messages)

    assert {:ok, %Definition{} = definition} =
             Messages.__translatable__({:definition, :ready_self})

    assert definition.application == :translatable
    assert definition.module == Messages
    assert definition.name == :ready_self
    assert definition.arity == 2
    assert definition.source_locale == "en"
    assert definition.source == "Ready ({ready, number} / {total, number})"
    assert definition.translator_note =~ "waits for every player"
    assert definition.translations == %{"es" => "Preparado ({ready, number} de {total, number})"}
    assert definition.valid?
    assert definition.errors == []

    assert %{
             total: %Param{name: :total, type: :number},
             ready: %Param{name: :ready, type: :number}
           } = definition.params
  end

  test "per-message attributes are cleared after defmsg except source locale" do
    assert {:ok, definition} = Messages.__translatable__({:definition, :hello})

    assert definition.source_locale == "en"
    assert definition.translator_note == nil
    assert definition.translations == %{}
    assert Map.keys(definition.params) == [:name]
  end

  test "module introspection returns the module definition shape" do
    assert %Translatable.Module{
             application: :translatable,
             module: Messages,
             source_locale: "en",
             messages: [%Definition{}, %Definition{}]
           } = Messages.__translatable__(:module)
  end

  test "defmsg block keeps message metadata attached to the source" do
    Code.compile_string("""
    defmodule TranslatableTest.BlockMessages do
      use Translatable

      defmsg ready(count) do
        translator_note "Shown in the lobby."
        param :count, :number, "The number of ready players"
        source "Ready {count}"
        translated_to "es", "Preparado {count}"
      end

      defmsg brand() do
        dont_translate()
        source "Pendulum"
      end

      defmsg hiya(), as: "Hi there"
    end
    """)

    assert {:ok, ready} =
             apply(TranslatableTest.BlockMessages, :__translatable__, [{:definition, :ready}])

    assert ready.source == "Ready {count}"
    assert ready.translator_note == "Shown in the lobby."
    assert ready.translations == %{"es" => "Preparado {count}"}
    assert %{count: %Param{type: :number}} = ready.params

    assert {:ok, brand} =
             apply(TranslatableTest.BlockMessages, :__translatable__, [{:definition, :brand}])

    refute brand.translatable?

    assert {:ok, hiya} =
             apply(TranslatableTest.BlockMessages, :__translatable__, [{:definition, :hiya}])

    assert hiya.source == "Hi there"
  end

  test "defmsg as shorthand warns when legacy directives are pending" do
    warning =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule TranslatableTest.AsWithPendingDirectives do
          use Translatable

          translated_to "es", "Hola"
          defmsg hiya(), as: "Hi there"
        end
        """)
      end)

    assert warning =~ "pending message directives before defmsg/2 :as form"

    assert {:ok, definition} =
             apply(TranslatableTest.AsWithPendingDirectives, :__translatable__, [
               {:definition, :hiya}
             ])

    assert definition.source == "Hi there"
    assert definition.translations == %{}
  end

  test "defmsg block warns when legacy directives are pending" do
    warning =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule TranslatableTest.BlockWithPendingDirectives do
          use Translatable

          translated_to "es", "Hola"

          defmsg hiya() do
            source "Hi there"
          end
        end
        """)
      end)

    assert warning =~ "pending message directives before defmsg/2 block form"

    assert {:ok, definition} =
             apply(TranslatableTest.BlockWithPendingDirectives, :__translatable__, [
               {:definition, :hiya}
             ])

    assert definition.source == "Hi there"
    assert definition.translations == %{}
  end

  test "invalid translatable metadata warns, compiles, and raises only when called" do
    warning =
      capture_io(:stderr, fn ->
        compiled =
          Code.compile_string("""
          defmodule TranslatableTest.InvalidMessages do
            use Translatable

            defmsg broken(ready) do
              param :ready, :number, "Ready players"
              source "Ready {ready, number}"
              translated_to "es", "Preparado {reedee, number}"
            end
          end
          """)

        assert {TranslatableTest.InvalidMessages, _bytecode} =
                 List.keyfind(compiled, TranslatableTest.InvalidMessages, 0)
      end)

    assert warning =~ "translation \"es\" references undeclared parameter :reedee"
    assert warning =~ "translation \"es\" does not reference declared parameter :ready"

    invalid_messages = TranslatableTest.InvalidMessages

    assert {:ok, definition} =
             apply(invalid_messages, :__translatable__, [{:definition, :broken}])

    refute definition.valid?

    assert_raise InvalidMessageError, ~r/TranslatableTest.InvalidMessages.broken/, fn ->
      apply(invalid_messages, :broken, [1])
    end
  end

  test "duplicate message names warn and definition lookup raises" do
    warning =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule TranslatableTest.DuplicateMessages do
          use Translatable

          defmsg duplicated(), as: "First"

          defmsg duplicated(name) do
            param :name, :string, "Name"
            source "Second {name}"
          end
        end
        """)
      end)

    assert warning =~ "defines duplicate message name :duplicated"

    duplicate_messages = TranslatableTest.DuplicateMessages

    assert [:duplicated, :duplicated] =
             apply(duplicate_messages, :__translatable__, [:messages])

    assert_raise InvalidMessageError, ~r/duplicate message name :duplicated/, fn ->
      apply(duplicate_messages, :__translatable__, [{:definition, :duplicated}])
    end
  end

  test "ICU parameter validation ignores plural branch text" do
    warning =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule TranslatableTest.PluralMessages do
          use Translatable

          defmsg item_count(count) do
            param :count, :number, "The item count"
            source "{count, plural, one {item} other {items}}"
          end
        end
        """)
      end)

    refute warning =~ "PluralMessages.item_count"

    assert {:ok, definition} =
             apply(TranslatableTest.PluralMessages, :__translatable__, [
               {:definition, :item_count}
             ])

    assert definition.valid?
  end

  test "ICU parameter validation sees adjacent parameters" do
    warning =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule TranslatableTest.AdjacentMessages do
          use Translatable

          defmsg pair(a, b) do
            param :a, :string, "The first value"
            param :b, :string, "The second value"
            source "{a}{b}"
          end
        end
        """)
      end)

    refute warning =~ "AdjacentMessages.pair"

    assert {:ok, definition} =
             apply(TranslatableTest.AdjacentMessages, :__translatable__, [{:definition, :pair}])

    assert definition.valid?
  end

  test "malformed DSL usage prevents compilation" do
    assert_raise ArgumentError, ~r/source\/1 requires a literal binary source/, fn ->
      Code.compile_string("""
      defmodule TranslatableTest.DynamicSourceMessages do
        use Translatable

        def source, do: "Hello"
        defmsg hello(), do: source()
      end
      """)
    end

    assert_raise ArgumentError, ~r/translatable_source\/1 expects a literal binary locale/, fn ->
      Code.compile_string("""
      defmodule TranslatableTest.BadSourceLocaleMessages do
        use Translatable

        translatable_source :en
      end
      """)
    end

    assert_raise ArgumentError, ~r/translator_note\/1 expects a literal binary note/, fn ->
      Code.compile_string("""
      defmodule TranslatableTest.BadTranslatorNoteMessages do
        use Translatable

        translator_note :not_a_string
      end
      """)
    end

    assert_raise ArgumentError, ~r/param\/3 expects a literal atom name/, fn ->
      Code.compile_string("""
      defmodule TranslatableTest.BadParamMessages do
        use Translatable

        param "ready", :number, "Ready players"
      end
      """)
    end

    assert_raise ArgumentError, ~r/translated_to\/2 expects literal binary locale/, fn ->
      Code.compile_string("""
      defmodule TranslatableTest.BadTranslationMessages do
        use Translatable

        translated_to :es, "Preparado"
      end
      """)
    end

    assert_raise ArgumentError, ~r/expects a local function call/, fn ->
      Code.compile_string("""
        defmodule TranslatableTest.RemoteDefmsgMessages do
          use Translatable

        defmsg Other.ready(), as: "Ready"
      end
      """)
    end

    assert_raise ArgumentError, ~r/arguments must be plain variables/, fn ->
      Code.compile_string("""
        defmodule TranslatableTest.PatternDefmsgMessages do
          use Translatable

        defmsg ready(%{count: count}) do
          source "Ready {count, number}"
        end
      end
      """)
    end
  end
end
