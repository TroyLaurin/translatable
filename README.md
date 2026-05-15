# Translatable

Translatable is an Elixir internationalisation workflow for defining
translatable messages in source code, extracting translator-facing bundles,
packaging runtime bundles, and validating translation state in CI.

It is currently being extracted from the Pendulum project and should be treated
as early, pre-release software.

See [docs/translatable.md](docs/translatable.md) for the current design notes
and workflow documentation.

## Compatibility

Translatable targets Elixir 1.14 and later. The compatibility floor is driven
by Plug 1.18, which is used by the optional web-language helpers.

The project includes Docker helpers for checking compatibility without changing
the local Elixir installation:

```sh
scripts/test-elixir
scripts/test-elixir-matrix
```

`scripts/test-elixir` accepts a `hexpm/elixir` image tag when checking a
specific runtime.
