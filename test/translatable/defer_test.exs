defmodule Translatable.DeferTest do
  use ExUnit.Case, async: true

  defmodule Messages do
    use Translatable

    translatable_source "en"

    defmsg hello(name) do
      param :name, :string, "The player's visible name"
      source "Hello {name}"
    end
  end

  defmodule Backend do
    use Translatable.Runtime

    source_lang "en"
    langs ["en", "es"]
    bundle_everything filename: "defer_test"
  end

  test "build defers pending messages and writes runtime source fallbacks" do
    extract = Translatable.Extract.build([Messages], app: :translatable)
    manifest = extract.manifest
    empty_lock = base_lock(%{})
    empty_runtime = %{"format" => "translatable.runtime.v1", "messages" => %{}}

    assert {:ok, result} =
             Translatable.Defer.build(
               manifest,
               extract.extract,
               empty_lock,
               empty_runtime,
               Backend,
               reason: "feature_flagged",
               link: "https://github.com/example/pendulum/issues/123"
             )

    key = key(:hello)

    assert result.deferred_count == 1
    assert result.lock["deferred"][key]["reason"] == "feature_flagged"

    assert result.lock["deferred"][key]["link"] ==
             "https://github.com/example/pendulum/issues/123"

    assert result.runtime["messages"][key] == %{"en" => "Hello {name}", "es" => "Hello {name}"}
  end

  test "write requires source manifest to be current" do
    paths = write_artifacts()
    stale_manifest = read_json!(paths.manifest)

    stale_manifest =
      update_in(stale_manifest["messages"], fn messages ->
        Enum.map(messages, &%{&1 | "source_hash" => "sha256:stale"})
      end)

    write_json!(paths.manifest, stale_manifest)

    assert {:error, [error]} =
             Translatable.Defer.write(
               :translatable,
               Backend,
               Backend.__translatable_runtime__(:bundle),
               modules: [Messages],
               manifest_path: paths.manifest,
               extract_path: paths.extract,
               lock_path: paths.lock,
               runtime_path: paths.runtime
             )

    assert error =~ "run mix translatable.extract first"
  end

  defp write_artifacts do
    dir = Path.join(System.tmp_dir!(), "translatable-defer-test-#{System.unique_integer()}")
    File.mkdir_p!(dir)

    extract = Translatable.Extract.build([Messages], app: :translatable)

    paths = %{
      manifest: Path.join(dir, "source.json"),
      extract: Path.join(dir, "extract.json"),
      lock: Path.join(dir, "lock.json"),
      runtime: Path.join(dir, "runtime.json")
    }

    write_json!(paths.manifest, extract.manifest)
    write_json!(paths.extract, extract.extract)
    write_json!(paths.lock, base_lock(%{}))
    write_json!(paths.runtime, %{"format" => "translatable.runtime.v1", "messages" => %{}})

    paths
  end

  defp base_lock(messages) do
    Translatable.Artifact.lock_bundle(
      :translatable,
      Backend,
      Backend.__translatable_runtime__(:bundle),
      "en",
      ["en", "es"],
      messages
    )
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
