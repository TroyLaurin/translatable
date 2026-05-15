defmodule Mix.Tasks.Translatable.Extract do
  @moduledoc """
  Extracts Translatable source metadata.

      $ mix translatable.extract

  The task writes a compact source manifest to `priv/translatable/source/` for
  committing, and a full source extraction bundle to
  `_build/#{Mix.env()}/translatable/extract/` for upload/transform workflows.
  """

  use Mix.Task

  @shortdoc "Extracts Translatable source metadata"

  @impl Mix.Task
  def run(_args) do
    app = Mix.Project.config() |> Keyword.fetch!(:app)
    Mix.Task.run("compile")

    backend = default_backend!(app)
    bundle = backend.__translatable_runtime__(:bundle) || missing_bundle!(backend)
    modules = Translatable.Extract.discover_modules(app)
    paths = Translatable.Extract.write(app, bundle, modules: modules)

    Mix.shell().info(
      "Extracted #{length(modules)} Translatable modules into #{length(paths.manifests)} bundles"
    )

    Mix.shell().info("Wrote source manifests under: #{common_path(paths.manifests)}")
    Mix.shell().info("Wrote full extracts under: #{common_path(paths.extracts)}")
  end

  defp default_backend!(app) do
    Application.get_env(:translatable, :default_backend) ||
      app
      |> Application.get_env(:translatable, [])
      |> Keyword.get(:default_backend) ||
      Mix.raise("""
      No default Translatable backend is configured.

      Configure one with:

          config :#{app}, :translatable,
            default_backend: MyApp.IsTranslatable
      """)
  end

  defp missing_bundle!(backend) do
    Mix.raise("""
    #{inspect(backend)} must configure a Translatable bundle before extraction.

    For example:

        bundle_everything filename: "my_app"
    """)
  end

  defp common_path([path]), do: path

  defp common_path(paths) do
    paths
    |> Enum.map(&Path.dirname/1)
    |> Enum.uniq()
    |> case do
      [path] -> path
      paths -> Enum.join(paths, ", ")
    end
  end
end
