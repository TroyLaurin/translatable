defmodule Translatable.BundleTest do
  use ExUnit.Case, async: true

  defmodule Demo.Messages do
  end

  defmodule Demo.Web.Messages do
  end

  defmodule Demo.Web.Game.Messages do
  end

  test "custom bundles route unmatched modules to default" do
    bundle =
      Translatable.Bundle.custom([path: "custom"], [
        Translatable.Bundle.default(filename: "default.json"),
        Translatable.Bundle.bundle(
          filename: "web.json",
          includes: [Translatable.Bundle.submodules(of: Demo.Web)]
        )
      ])

    shards = Translatable.Bundle.runtime_shards(bundle, [Demo.Messages, Demo.Web.Messages])

    assert Enum.map(shards, & &1.id) == ["custom/default", "custom/web"]

    assert [%{modules: [Demo.Messages]}, %{modules: [Demo.Web.Messages]}] = shards
  end

  test "custom bundles route to the most specific submodule matcher" do
    bundle =
      Translatable.Bundle.custom([path: "custom"], [
        Translatable.Bundle.default(filename: "default.json"),
        Translatable.Bundle.bundle(
          filename: "web.json",
          includes: [Translatable.Bundle.submodules(of: Demo.Web)]
        ),
        Translatable.Bundle.bundle(
          filename: "game.json",
          includes: [Translatable.Bundle.submodules(of: Demo.Web.Game)]
        )
      ])

    shards =
      Translatable.Bundle.runtime_shards(bundle, [Demo.Web.Messages, Demo.Web.Game.Messages])

    assert Enum.map(shards, & &1.id) == ["custom/web", "custom/game"]
    assert Enum.at(shards, 0).modules == [Demo.Web.Messages]
    assert Enum.at(shards, 1).modules == [Demo.Web.Game.Messages]
  end

  test "custom bundles reject duplicate filenames" do
    assert_raise ArgumentError, ~r/filenames must be unique/, fn ->
      Translatable.Bundle.custom([path: "custom"], [
        Translatable.Bundle.default(filename: "default.json"),
        Translatable.Bundle.bundle(
          filename: "web.json",
          includes: [Translatable.Bundle.submodules(of: Demo.Web)]
        ),
        Translatable.Bundle.bundle(
          filename: "web.json",
          includes: [Translatable.Bundle.submodules(of: Demo.Web.Game)]
        )
      ])
    end
  end

  test "custom bundles reject equal specificity routing ties" do
    bundle =
      Translatable.Bundle.custom([path: "custom"], [
        Translatable.Bundle.default(filename: "default.json"),
        Translatable.Bundle.bundle(
          filename: "first.json",
          includes: [Translatable.Bundle.submodules(of: Demo.Web)]
        ),
        Translatable.Bundle.bundle(
          filename: "second.json",
          includes: [Translatable.Bundle.submodules(of: Demo.Web)]
        )
      ])

    assert_raise ArgumentError, ~r/equal specificity/, fn ->
      Translatable.Bundle.runtime_shards(bundle, [Demo.Web.Messages])
    end
  end
end
