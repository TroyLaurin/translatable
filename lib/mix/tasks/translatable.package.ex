defmodule Mix.Tasks.Translatable.Package do
  @moduledoc """
  Packages translated Translatable input into runtime JSON bundles.

      $ mix translatable.package
      $ mix translatable.package path/to/translations.json path/to/more_translations.json
      $ cat translations.json | mix translatable.package -

  The task requires at least one explicit input path. Use `-` to read the
  canonical translations JSON from stdin.
  """

  use Mix.Task

  @shortdoc "Packages Translatable runtime JSON bundles"

  @impl Mix.Task
  def run(args) do
    app = Mix.Project.config() |> Keyword.fetch!(:app)
    Mix.Task.run("compile")

    backend = default_backend!(app)
    bundle = backend.__translatable_runtime__(:bundle) || missing_bundle!(backend)
    translations_input = translations_input(args)

    case Translatable.Package.write(app, backend, bundle, translations_input) do
      {:ok, result} ->
        Mix.shell().info(
          "Packaged #{result.translation_count} translations for #{result.message_count} messages"
        )

        Mix.shell().info("Wrote runtime bundles under: #{common_path(result.runtimes)}")
        Mix.shell().info("Wrote translation locks under: #{common_path(result.locks)}")

      {:error, errors} ->
        Mix.raise("Unable to package translations:\n\n" <> Enum.join(errors, "\n"))
    end
  end

  defp translations_input(["-"]), do: {:stdin, IO.read(:stdio, :eof)}
  defp translations_input([path]), do: path
  defp translations_input(paths) when is_list(paths) and paths != [], do: paths

  defp translations_input(_args) do
    Mix.raise("Expected at least one translation input path, or - for stdin")
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
    #{inspect(backend)} must configure a Translatable bundle before packaging.

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
