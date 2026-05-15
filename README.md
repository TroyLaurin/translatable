# Translatable

Translatable is an Elixir internationalisation workflow for defining
translatable messages in source code, extracting translator-facing bundles,
packaging runtime bundles, and validating translation state in CI.

It is currently being extracted from the Pendulum project and should be treated
as early, pre-release software.

See [docs/translatable.md](docs/translatable.md) for the current design notes
and workflow documentation.

The package input contract is documented in
[docs/package-input.md](docs/package-input.md), with a JSON Schema at
[docs/schemas/package-input.schema.json](docs/schemas/package-input.schema.json).

## Compatibility

Translatable targets Elixir 1.15 and later.

The project includes Docker helpers for checking compatibility without changing
the local Elixir installation:

```sh
scripts/test-elixir
scripts/test-elixir-matrix
```

`scripts/test-elixir` accepts an Elixir Docker image name when checking a
specific runtime.
