defmodule Mix.Tasks.Translatable.Validate do
  @moduledoc """
  Validates Translatable backend configuration and translation artifacts.

      $ mix translatable.validate
  """

  use Mix.Task

  @shortdoc "Validates Translatable configuration and bundles"

  @impl Mix.Task
  def run(_args) do
    app = Mix.Project.config() |> Keyword.fetch!(:app)
    Mix.Task.run("compile")

    case Translatable.Validate.validate(app) do
      {:ok, issues} ->
        print_issues(issues)
        Mix.shell().info("Translatable validation passed")

      {:error, issues} ->
        print_issues(issues)
        Mix.raise("Translatable validation failed with #{count(issues, :error)} errors")
    end
  end

  defp print_issues(issues) do
    issues
    |> Enum.reverse()
    |> Enum.each(fn issue ->
      prefix =
        issue.severity
        |> Atom.to_string()
        |> String.upcase()

      Mix.shell().info("#{prefix} #{issue.code}: #{issue.message}")
    end)
  end

  defp count(issues, severity), do: Enum.count(issues, &(&1.severity == severity))
end
