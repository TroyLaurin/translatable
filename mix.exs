defmodule Translatable.MixProject do
  use Mix.Project

  def project do
    [
      app: :translatable,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      package: package(),
      description: description(),
      docs: docs(),
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.2"},
      {:plug, "~> 1.18"},
      {:expo, "~> 1.1"},
      {:ex_doc, "~> 0.36", only: :dev, runtime: false},
      {:ex_cldr, "~> 2.47", only: [:dev, :test], optional: true},
      {:ex_cldr_numbers, "~> 2.34", only: [:dev, :test], optional: true},
      {:ex_cldr_messages, "~> 2.0", only: [:dev, :test], optional: true}
    ]
  end

  defp aliases do
    [
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end

  defp description do
    "Source-defined translatable messages and translation workflow tooling for Elixir."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/TroyLaurin/translatable"}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "docs/translatable.md",
        "docs/package-input.md"
      ],
      groups_for_modules: [
        Runtime: [
          Translatable.Runtime,
          Translatable.Message,
          Translatable.Runtime.Error,
          Translatable.Runtime.Messages
        ],
        Workflow: [
          Translatable.Extract,
          Translatable.Package,
          Translatable.Validate,
          Translatable.Defer,
          Translatable.Bundle,
          Translatable.Validation.Issue
        ],
        Providers: [
          Translatable.Provider,
          Translatable.Provider.Json,
          Translatable.Provider.Source,
          Translatable.Provider.PO,
          Translatable.Provider.Gettext
        ],
        Interpolation: [
          Translatable.Interpolator,
          Translatable.Interpolator.Simple,
          Translatable.Interpolator.Cldr
        ],
        Plug: [
          Translatable.Plug.AcceptLanguage,
          Translatable.Plug.GetLanguage,
          Translatable.Plug.SessionLanguage
        ]
      ]
    ]
  end
end
