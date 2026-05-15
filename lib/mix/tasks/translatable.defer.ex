defmodule Mix.Tasks.Translatable.Defer do
  @moduledoc """
  Defers outstanding Translatable translations and writes safe runtime fallbacks.

      $ mix translatable.defer --reason feature_flagged --link https://github.com/my/app/issues/123
  """

  use Mix.Task

  @shortdoc "Defers outstanding Translatable translations"

  @impl Mix.Task
  def run(args) do
    app = Mix.Project.config() |> Keyword.fetch!(:app)
    Mix.Task.run("compile")

    {opts, _argv, _invalid} =
      OptionParser.parse(args, switches: [reason: :string, link: :string])

    backend = default_backend!(app)
    bundle = backend.__translatable_runtime__(:bundle) || missing_bundle!(backend)

    case Translatable.Defer.write(app, backend, bundle, opts) do
      {:ok, result} ->
        Mix.shell().info("Deferred #{result.deferred_count} Translatable messages")
        Mix.shell().info("Wrote runtime bundle: #{result.runtime}")
        Mix.shell().info("Wrote translation lock: #{result.lock}")

      {:error, errors} ->
        Mix.raise("Unable to defer translations:\n\n" <> Enum.join(errors, "\n"))
    end
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
    #{inspect(backend)} must configure a Translatable bundle before deferring translations.

    For example:

        bundle_everything filename: "my_app"
    """)
  end
end
