defmodule Translatable.PackageTest do
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
    langs ["en", "es", "de"]
    bundle_everything filename: "package_test"
  end

  test "build packages backend languages into runtime provider JSON" do
    translations = translations_bundle()

    assert {:ok, package} =
             Translatable.Package.build([Messages], translations, Backend,
               app: :translatable,
               bundle: Backend.__translatable_runtime__(:bundle)
             )

    assert package.runtime == %{
             "format" => "translatable.runtime.v1",
             "messages" => %{
               "translatable:Translatable.PackageTest.Messages.brand" => %{
                 "de" => "Pendulum",
                 "en" => "Pendulum",
                 "es" => "Pendulum"
               },
               "translatable:Translatable.PackageTest.Messages.hello" => %{
                 "de" => "Hallo {name}",
                 "en" => "Hello {name}",
                 "es" => "Hola {name}"
               }
             }
           }

    assert package.lock["format"] == "translatable.lock.v1"
    assert package.lock["application"] == "translatable"
    assert package.lock["backend"] == "Translatable.PackageTest.Backend"
    assert package.lock["langs"] == ["en", "es", "de"]

    assert package.lock["bundle"] == %{
             "strategy" => "everything",
             "path" => "",
             "filename" => "package_test"
           }

    assert %{
             "translatable" => false,
             "langs" => %{
               "de" => %{"status" => "dont_translate"},
               "en" => %{"status" => "source"},
               "es" => %{"status" => "dont_translate"}
             }
           } = package.lock["messages"]["translatable:Translatable.PackageTest.Messages.brand"]

    assert %{
             "translatable" => true,
             "langs" => %{
               "de" => %{"status" => "translated"},
               "en" => %{"status" => "source"},
               "es" => %{"status" => "translated"}
             }
           } = package.lock["messages"]["translatable:Translatable.PackageTest.Messages.hello"]
  end

  test "build rejects stale source fingerprints" do
    translations =
      update_in(translations_bundle(), ["messages", Access.at(0), "source_hash"], fn _hash ->
        "sha256:stale"
      end)

    assert {:error, [error]} =
             Translatable.Package.build([Messages], translations, Backend, app: :translatable)

    assert error =~ "has stale source_hash"
  end

  test "build removes deferrals for successfully packaged current hashes" do
    translations = translations_bundle()
    source_message = source_message(:hello)

    existing_lock =
      Translatable.Artifact.lock_bundle(
        :translatable,
        Backend,
        Backend.__translatable_runtime__(:bundle),
        "en",
        ["en", "es", "de"],
        %{},
        %{
          source_message["key"] => %{
            "source_hash" => source_message["source_hash"],
            "params_hash" => source_message["params_hash"],
            "definition_hash" => source_message["definition_hash"],
            "langs" => ["en", "es", "de"]
          }
        }
      )

    assert {:ok, package} =
             Translatable.Package.build([Messages], translations, Backend,
               app: :translatable,
               bundle: Backend.__translatable_runtime__(:bundle),
               existing_lock: existing_lock
             )

    refute Map.has_key?(package.lock, "deferred")
  end

  test "write removes matching deferrals from the existing lock file" do
    dir = Path.join(System.tmp_dir!(), "translatable-package-test-#{System.unique_integer()}")
    runtime_path = Path.join(dir, "runtime.json")
    lock_path = Path.join(dir, "lock.json")
    translations_path = Path.join(dir, "translations.json")
    source_message = source_message(:hello)

    existing_lock =
      Translatable.Artifact.lock_bundle(
        :translatable,
        Backend,
        Backend.__translatable_runtime__(:bundle),
        "en",
        ["en", "es", "de"],
        %{},
        %{
          source_message["key"] => %{
            "source_hash" => source_message["source_hash"],
            "params_hash" => source_message["params_hash"],
            "definition_hash" => source_message["definition_hash"],
            "langs" => ["en", "es", "de"]
          }
        }
      )

    write_json!(lock_path, existing_lock)
    write_json!(translations_path, translations_bundle())

    assert {:ok, _result} =
             Translatable.Package.write(
               :translatable,
               Backend,
               Backend.__translatable_runtime__(:bundle),
               translations_path,
               modules: [Messages],
               runtime_path: runtime_path,
               lock_path: lock_path
             )

    refute Map.has_key?(read_json!(lock_path), "deferred")
  end

  test "write supports per-module runtime and lock bundles" do
    tmp_dir = Path.join(System.tmp_dir!(), "translatable-package-per-module-test")
    path_prefix = "package_per_module_test_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      File.rm_rf!(Path.join(["priv", "translatable", "runtime", path_prefix]))
      File.rm_rf!(Path.join(["priv", "translatable", "lock", path_prefix]))
    end)

    bundle = Translatable.Bundle.per_module(path: path_prefix)
    translations_path = Path.join(tmp_dir, "translations.json")

    write_json!(translations_path, translations_bundle())

    assert {:ok, result} =
             Translatable.Package.write(:translatable, Backend, bundle, translations_path,
               modules: [Messages]
             )

    assert length(result.runtimes) == 1
    assert length(result.locks) == 1
    assert File.exists?(hd(result.runtimes))
    assert File.exists?(hd(result.locks))

    runtime_manifest =
      ["priv", "translatable", "runtime", path_prefix, "manifest.json"]
      |> Path.join()
      |> read_json!()

    assert [%{"id" => id, "runtime_path" => "Translatable.PackageTest.Messages.json"}] =
             runtime_manifest["shards"]

    assert id == Path.join(path_prefix, "Translatable.PackageTest.Messages")

    runtime = read_json!(hd(result.runtimes))

    assert runtime["messages"]["translatable:Translatable.PackageTest.Messages.hello"]["es"] ==
             "Hola {name}"
  end

  test "read_translations_input accepts stdin content" do
    body = Jason.encode!(translations_bundle())

    assert {:ok, %{"format" => "translatable.translations.v1"}} =
             Translatable.Package.read_translations_input({:stdin, body})
  end

  test "read_translations_input accepts the documented example" do
    path = Path.expand("../../examples/package-input.json", __DIR__)

    assert {:ok, %{"messages" => [_message]}} =
             Translatable.Package.read_translations_input(path)
  end

  test "read_translations_input rejects malformed package input" do
    input = %{
      "format" => "translatable.translations.v1",
      "messages" => [
        %{
          "key" => "demo:Messages.hello",
          "source_hash" => "not-a-hash",
          "params_hash" =>
            "sha256:0000000000000000000000000000000000000000000000000000000000000002",
          "definition_hash" =>
            "sha256:0000000000000000000000000000000000000000000000000000000000000003",
          "translations" => [
            %{"lang" => "es", "text" => "Hola"},
            %{"lang" => "es", "text" => "Buenas"}
          ]
        },
        %{
          "key" => "demo:Messages.hello",
          "source_hash" =>
            "sha256:0000000000000000000000000000000000000000000000000000000000000001",
          "params_hash" =>
            "sha256:0000000000000000000000000000000000000000000000000000000000000002",
          "definition_hash" =>
            "sha256:0000000000000000000000000000000000000000000000000000000000000003",
          "translations" => [%{"lang" => "de"}]
        }
      ]
    }

    assert {:error, errors} =
             input
             |> Jason.encode!()
             |> then(&Translatable.Package.read_translations_input({:stdin, &1}))

    assert Enum.any?(errors, &(&1 =~ "/messages/0/source_hash"))
    assert Enum.any?(errors, &(&1 =~ "duplicate translation lang \"es\""))
    assert Enum.any?(errors, &(&1 =~ "/messages/1/translations/0/text is required"))
    assert Enum.any?(errors, &(&1 =~ "duplicate message key \"demo:Messages.hello\""))
  end

  test "read_translations_input reports schema errors for files directly" do
    dir = Path.join(System.tmp_dir!(), "translatable-package-schema-test")
    path = Path.join(dir, "translations.json")

    write_json!(path, %{"format" => "translatable.translations.v1", "messages" => [%{}]})

    assert {:error, errors} = Translatable.Package.read_translations_input(path)
    assert Enum.any?(errors, &(&1 == "/messages/0/key is required"))
  end

  defp translations_bundle do
    source_message = source_message(:hello)

    %{
      "format" => "translatable.translations.v1",
      "messages" => [
        %{
          "key" => source_message["key"],
          "source_lang" => source_message["source_lang"],
          "source_hash" => source_message["source_hash"],
          "params_hash" => source_message["params_hash"],
          "definition_hash" => source_message["definition_hash"],
          "translations" => [
            %{"lang" => "es", "text" => "Hola {name}"},
            %{"lang" => "de", "text" => "Hallo {name}"},
            %{"lang" => "fr", "text" => "Bonjour {name}"}
          ]
        }
      ]
    }
  end

  defp source_message(name) do
    {:ok, definition} = Messages.__translatable__({:definition, name})
    key = Translatable.Definition.external_key(definition)

    [Messages]
    |> Translatable.Extract.build(app: :translatable)
    |> get_in([:extract, "messages"])
    |> Enum.find(&(&1["key"] == key))
  end

  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()

  defp write_json!(path, data) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(path, Jason.encode_to_iodata!(data, pretty: true))
  end
end
