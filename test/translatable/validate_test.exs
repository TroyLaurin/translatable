defmodule Translatable.ValidateTest do
  use ExUnit.Case, async: true

  defmodule Messages do
    use Translatable

    translatable_source "en"

    defmsg hello(name) do
      param :name, :string, "The player's visible name"
      source "Hello {name}"
    end

    defmsg brand() do
      dont_translate()
      source "Pendulum"
    end
  end

  defmodule Backend do
    use Translatable.Runtime

    source_lang "en"
    langs ["en", "es"]
    bundle_everything filename: "validate_test"
    provider Translatable.Provider.Source
  end

  test "validate passes for current source, lock, and runtime bundles" do
    paths = write_valid_artifacts()

    assert {:ok, []} =
             Translatable.Validate.validate(:translatable,
               backend: Backend,
               modules: [Messages],
               manifest_path: paths.manifest,
               lock_path: paths.lock,
               runtime_path: paths.runtime
             )
  end

  test "validate reports stale source manifests" do
    paths = write_valid_artifacts()
    manifest = read_json!(paths.manifest)

    manifest =
      update_in(manifest["messages"], fn messages ->
        Enum.reject(messages, &(&1["key"] =~ ".hello"))
      end)

    write_json!(paths.manifest, manifest)

    assert {:error, issues} =
             Translatable.Validate.validate(:translatable,
               backend: Backend,
               modules: [Messages],
               manifest_path: paths.manifest,
               lock_path: paths.lock,
               runtime_path: paths.runtime
             )

    assert Enum.any?(issues, &(&1.code == :missing_artifact_message))
  end

  test "validate reports only the source hash when source and definition hashes drift" do
    paths = write_valid_artifacts()
    manifest = read_json!(paths.manifest)
    lock = read_json!(paths.lock)
    key = key(:hello)

    manifest =
      update_in(manifest["messages"], fn messages ->
        Enum.map(messages, fn
          %{"key" => ^key} = message ->
            %{
              message
              | "source_hash" => "sha256:old-source",
                "definition_hash" => "sha256:old-definition"
            }

          message ->
            message
        end)
      end)

    lock =
      put_in(lock, ["messages", key, "source_hash"], "sha256:old-source")
      |> put_in(["messages", key, "definition_hash"], "sha256:old-definition")

    write_json!(paths.manifest, manifest)
    write_json!(paths.lock, lock)

    assert {:error, issues} =
             Translatable.Validate.validate(:translatable,
               backend: Backend,
               modules: [Messages],
               manifest_path: paths.manifest,
               lock_path: paths.lock,
               runtime_path: paths.runtime
             )

    stale_hashes = Enum.filter(issues, &(&1.code == :stale_hash))

    assert [%{context: %{artifact: :source_manifest, field: "source_hash"}}] = stale_hashes
  end

  test "validate compares lock hashes to the persisted source manifest" do
    paths = write_valid_artifacts()
    manifest = read_json!(paths.manifest)
    lock = read_json!(paths.lock)
    key = key(:hello)

    manifest =
      update_in(manifest["messages"], fn messages ->
        Enum.map(messages, fn
          %{"key" => ^key} = message -> %{message | "source_hash" => "sha256:persisted-source"}
          message -> message
        end)
      end)

    lock = put_in(lock, ["messages", key, "source_hash"], "sha256:persisted-source")

    write_json!(paths.manifest, manifest)
    write_json!(paths.lock, lock)

    assert {:error, issues} =
             Translatable.Validate.validate(:translatable,
               backend: Backend,
               modules: [Messages],
               manifest_path: paths.manifest,
               lock_path: paths.lock,
               runtime_path: paths.runtime
             )

    refute Enum.any?(issues, &(&1.context[:artifact] == :lock))
    assert Enum.any?(issues, &(&1.context[:artifact] == :source_manifest))
  end

  test "validate reports malformed runtime translation bindings" do
    paths = write_valid_artifacts()
    runtime = read_json!(paths.runtime)
    key = key(:hello)

    runtime = put_in(runtime, ["messages", key, "es"], "Hola {missing}")
    write_json!(paths.runtime, runtime)

    assert {:error, issues} =
             Translatable.Validate.validate(:translatable,
               backend: Backend,
               modules: [Messages],
               manifest_path: paths.manifest,
               lock_path: paths.lock,
               runtime_path: paths.runtime
             )

    assert Enum.any?(issues, &(&1.code == :invalid_bindings))
    assert Enum.any?(issues, &String.contains?(&1.message, ":missing"))
  end

  test "validate downgrades deferred lock and runtime gaps to warnings" do
    paths = write_valid_artifacts()
    manifest = read_json!(paths.manifest)
    lock = read_json!(paths.lock)
    runtime = read_json!(paths.runtime)
    key = key(:hello)
    message = Enum.find(manifest["messages"], &(&1["key"] == key))

    lock =
      lock
      |> update_in(["messages"], &Map.delete(&1, key))
      |> put_in(["deferred"], %{
        key => %{
          "source_hash" => message["source_hash"],
          "params_hash" => message["params_hash"],
          "definition_hash" => message["definition_hash"],
          "langs" => ["en", "es"]
        }
      })

    runtime = update_in(runtime["messages"], &Map.delete(&1, key))

    write_json!(paths.lock, lock)
    write_json!(paths.runtime, runtime)

    assert {:ok, issues} =
             Translatable.Validate.validate(:translatable,
               backend: Backend,
               modules: [Messages],
               manifest_path: paths.manifest,
               lock_path: paths.lock,
               runtime_path: paths.runtime
             )

    assert Enum.any?(issues, &(&1.code == :deferred_artifact_message))
    assert Enum.any?(issues, &(&1.code == :deferred_runtime_message))
  end

  test "validate passes for per-module bundle artifacts" do
    tmp_dir = Path.join(System.tmp_dir!(), "translatable-validate-per-module-test")
    File.mkdir_p!(tmp_dir)
    path_prefix = "validate_per_module_test_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      File.rm_rf!(Path.join(["priv", "translatable", "source", path_prefix]))
      File.rm_rf!(Path.join(["priv", "translatable", "runtime", path_prefix]))
      File.rm_rf!(Path.join(["priv", "translatable", "lock", path_prefix]))
    end)

    [{backend, _bytecode}] =
      Code.compile_string("""
      defmodule Translatable.ValidateTest.PerModuleBackend do
        use Translatable.Runtime

        source_lang "en"
        langs ["en", "es"]
        bundle_per_module path: #{inspect(path_prefix)}
        provider Translatable.Provider.Source
      end
      """)

    bundle = backend.__translatable_runtime__(:bundle)
    Translatable.Extract.write(:translatable, bundle, modules: [Messages])

    extract = Translatable.Extract.build([Messages], app: :translatable)
    translations = translations_bundle(extract.extract)
    translations_path = Path.join(tmp_dir, "translations.json")
    write_json!(translations_path, translations)

    assert {:ok, _result} =
             Translatable.Package.write(:translatable, backend, bundle, translations_path,
               modules: [Messages]
             )

    assert {:ok, []} =
             Translatable.Validate.validate(:translatable,
               backend: backend,
               modules: [Messages]
             )
  end

  defp write_valid_artifacts do
    dir = Path.join(System.tmp_dir!(), "translatable-validate-test-#{System.unique_integer()}")
    File.mkdir_p!(dir)

    extract = Translatable.Extract.build([Messages], app: :translatable)
    translations = translations_bundle(extract.extract)

    assert {:ok, package} =
             Translatable.Package.build([Messages], translations, Backend,
               app: :translatable,
               bundle: Backend.__translatable_runtime__(:bundle)
             )

    paths = %{
      manifest: Path.join(dir, "source.json"),
      lock: Path.join(dir, "lock.json"),
      runtime: Path.join(dir, "runtime.json")
    }

    write_json!(paths.manifest, extract.manifest)
    write_json!(paths.lock, package.lock)
    write_json!(paths.runtime, package.runtime)

    paths
  end

  defp translations_bundle(%{"messages" => messages}) do
    hello = Enum.find(messages, &(&1["key"] == key(:hello)))

    %{
      "format" => "translatable.translations.v1",
      "messages" => [
        %{
          "key" => hello["key"],
          "source_hash" => hello["source_hash"],
          "params_hash" => hello["params_hash"],
          "definition_hash" => hello["definition_hash"],
          "translations" => [%{"lang" => "es", "text" => "Hola {name}"}]
        }
      ]
    }
  end

  defp key(name) do
    {:ok, definition} = Messages.__translatable__({:definition, name})
    Translatable.Definition.external_key(definition)
  end

  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()

  defp write_json!(path, data) do
    File.write!(path, Jason.encode_to_iodata!(data, pretty: true))
  end
end
