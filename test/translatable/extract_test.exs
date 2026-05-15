defmodule Translatable.ExtractTest do
  use ExUnit.Case, async: true

  defmodule Messages do
    use Translatable

    translatable_source "en"

    defmsg hello(name) do
      translator_note "Shown on the welcome screen."
      param :name, :string, "The player's visible name"
      source "Hello {name}"
      translated_to "es", "Hola {name}"
    end

    defmsg brand() do
      dont_translate()
      source "Pendulum"
    end
  end

  defmodule Web.Messages do
    use Translatable

    translatable_source "en"

    defmsg heading() do
      source "Welcome"
    end
  end

  test "build returns deterministic extract and source manifest bundles" do
    assert %{extract: extract, manifest: manifest} =
             Translatable.Extract.build([Messages], app: :translatable)

    assert extract["format"] == "translatable.extract.v1"
    assert extract["application"] == "translatable"

    assert [%{"module" => "Translatable.ExtractTest.Messages", "message_count" => 2}] =
             extract["modules"]

    assert [brand, hello] = extract["messages"]

    assert brand["key"] == "translatable:Translatable.ExtractTest.Messages.brand"
    assert brand["source"] == "Pendulum"
    refute brand["translatable"]
    assert brand["params"] == []
    assert brand["translations"] == []
    assert brand["source_hash"] =~ ~r/^sha256:[0-9a-f]{64}$/

    assert hello["key"] == "translatable:Translatable.ExtractTest.Messages.hello"
    assert hello["source_lang"] == "en"
    assert hello["source"] == "Hello {name}"
    assert hello["translator_note"] == "Shown on the welcome screen."

    assert hello["params"] == [
             %{"name" => "name", "type" => "string", "note" => "The player's visible name"}
           ]

    assert hello["translations"] == [%{"lang" => "es", "text" => "Hola {name}"}]
    assert hello["definition_hash"] =~ ~r/^sha256:[0-9a-f]{64}$/

    assert manifest["format"] == "translatable.source-manifest.v1"
    assert manifest["application"] == "translatable"

    assert Enum.map(manifest["messages"], & &1["key"]) == [
             brand["key"],
             hello["key"]
           ]

    refute hd(manifest["messages"])["source"]
  end

  test "write derives output paths from the configured bundle" do
    bundle = Translatable.Bundle.everything(filename: "test_bundle", path: "demo")
    tmp_dir = Path.join(System.tmp_dir!(), "translatable-extract-test")

    paths =
      Translatable.Extract.write(:translatable, bundle,
        modules: [Messages],
        manifest_path: Path.join(tmp_dir, "manifest.json"),
        extract_path: Path.join(tmp_dir, "extract.json")
      )

    assert paths.manifest == Path.join(tmp_dir, "manifest.json")
    assert paths.extract == Path.join(tmp_dir, "extract.json")
    assert File.exists?(paths.manifest)
    assert File.exists?(paths.extract)

    assert Translatable.Bundle.manifest_path(bundle) ==
             "priv/translatable/source/demo/test_bundle.json"

    assert Translatable.Bundle.extract_path(bundle, build_path: "_build/test") ==
             "_build/test/translatable/extract/demo/test_bundle.json"

    assert Translatable.Bundle.runtime_path(bundle) ==
             "priv/translatable/runtime/demo/test_bundle.json"

    assert Translatable.Bundle.lock_path(bundle) ==
             "priv/translatable/lock/demo/test_bundle.json"
  end

  test "write supports per-module bundles with bundle manifests" do
    tmp_dir = Path.join(System.tmp_dir!(), "translatable-extract-per-module-test")
    build_path = Path.join(tmp_dir, "_build")
    path_prefix = "extract_per_module_test_#{System.unique_integer([:positive])}"
    source_root = Path.join(["priv", "translatable", "source", path_prefix])
    on_exit(fn -> File.rm_rf!(Path.join(["priv", "translatable", "source", path_prefix])) end)
    bundle = Translatable.Bundle.per_module(path: path_prefix)

    paths =
      Translatable.Extract.write(:translatable, bundle,
        modules: [Messages],
        build_path: build_path
      )

    source_path =
      Path.join([
        source_root,
        "Translatable.ExtractTest.Messages.json"
      ])

    extract_path =
      Path.join([
        build_path,
        "translatable",
        "extract",
        path_prefix,
        "Translatable.ExtractTest.Messages.json"
      ])

    assert Enum.map(paths.manifests, &Path.expand/1) == [Path.expand(source_path)]
    assert Enum.map(paths.extracts, &Path.expand/1) == [Path.expand(extract_path)]
    assert File.exists?(hd(paths.manifests))
    assert File.exists?(hd(paths.extracts))

    source_manifest =
      [source_root, "manifest.json"]
      |> Path.join()
      |> read_json!()

    assert [%{"id" => id}] =
             source_manifest["shards"]

    assert id == Path.join(path_prefix, "Translatable.ExtractTest.Messages")
  end

  test "write supports custom bundle groups" do
    tmp_dir = Path.join(System.tmp_dir!(), "translatable-extract-custom-test")
    build_path = Path.join(tmp_dir, "_build")
    path_prefix = "extract_custom_test_#{System.unique_integer([:positive])}"

    on_exit(fn -> File.rm_rf!(Path.join(["priv", "translatable", "source", path_prefix])) end)

    bundle =
      Translatable.Bundle.custom([path: path_prefix], [
        Translatable.Bundle.default(filename: "default.json"),
        Translatable.Bundle.bundle(
          filename: "web.json",
          includes: [Translatable.Bundle.submodules(of: __MODULE__.Web)]
        )
      ])

    paths =
      Translatable.Extract.write(:translatable, bundle,
        modules: [Messages, Web.Messages],
        build_path: build_path
      )

    assert Enum.map(paths.manifests, &Path.basename/1) == ["default.json", "web.json"]

    manifest =
      ["priv", "translatable", "source", path_prefix, "manifest.json"]
      |> Path.join()
      |> read_json!()

    assert Enum.map(manifest["shards"], & &1["source_path"]) == ["default.json", "web.json"]
  end

  test "write warns when extracting a changed message with an active deferral" do
    bundle = Translatable.Bundle.everything(filename: "test_bundle", path: "demo")
    tmp_dir = Path.join(System.tmp_dir!(), "translatable-extract-deferred-test")
    manifest_path = Path.join(tmp_dir, "manifest.json")
    extract_path = Path.join(tmp_dir, "extract.json")
    lock_path = Path.join(tmp_dir, "lock.json")

    current = Translatable.Extract.build([Messages], app: :translatable)
    [hello] = Enum.filter(current.manifest["messages"], &(&1["key"] =~ ".hello"))

    lock =
      Translatable.Artifact.lock_bundle(:translatable, __MODULE__, bundle, "en", ["en"], %{}, %{
        hello["key"] => %{hello | "source_hash" => "sha256:older"}
      })

    File.mkdir_p!(tmp_dir)
    File.write!(lock_path, Jason.encode_to_iodata!(lock))

    warning =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        Translatable.Extract.write(:translatable, bundle,
          modules: [Messages],
          manifest_path: manifest_path,
          extract_path: extract_path,
          lock_path: lock_path
        )
      end)

    assert warning =~ "active Translatable deferral"
    assert warning =~ hello["key"]
  end

  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()
end
