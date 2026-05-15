defmodule Mix.Tasks.Translatable.Validate do
  @moduledoc """
  Validates Translatable backend configuration and translation artifacts.

      $ mix translatable.validate
      $ mix translatable.validate --format-json
  """

  use Mix.Task

  @shortdoc "Validates Translatable configuration and bundles"

  @impl Mix.Task
  def run(args) do
    app = Mix.Project.config() |> Keyword.fetch!(:app)
    Mix.Task.run("compile")
    opts = parse_args!(args)

    case Translatable.Validate.validate(app) do
      {:ok, issues} ->
        print_issues(issues, opts)
        print_success(opts)

      {:error, issues} ->
        print_issues(issues, opts)
        Mix.raise("Translatable validation failed with #{count(issues, :error)} errors")
    end
  end

  defp parse_args!(args) do
    case OptionParser.parse(args, strict: [format_json: :boolean]) do
      {opts, [], []} ->
        opts

      {_opts, _args, invalid} ->
        invalid =
          invalid
          |> Enum.map(fn {option, _value} -> option end)
          |> Enum.join(", ")

        Mix.raise("Unknown translatable.validate option(s): #{invalid}")
    end
  end

  defp print_issues([], _opts), do: :ok

  defp print_issues(issues, opts) do
    output =
      if Keyword.get(opts, :format_json, false) do
        Translatable.Validate.Reporter.json(issues)
      else
        Translatable.Validate.Reporter.text(issues)
      end

    Mix.shell().info(output)
  end

  defp print_success(opts) do
    unless Keyword.get(opts, :format_json, false) do
      Mix.shell().info("Translatable validation passed")
    end
  end

  defp count(issues, severity), do: Enum.count(issues, &(&1.severity == severity))
end
