# Translatable

Translatable is an in-progress Elixir internationalisation workflow that was
incubated inside Pendulum before being extracted into a standalone library.

The central idea is that source code defines messages that are translatable, and
the workflow around those messages makes it visible when translations are
missing, stale, or intentionally deferred.

## Mental Model

Message modules are the source of truth:

```elixir
defmodule MyAppWeb.LoginMessages do
  use Translatable

  translatable_source "en"

  defmsg submit_button() do
    source "Sign in"
    translated_to "es", "Iniciar sesión"
  end

  defmsg greeting(name) do
    translator_note "Shown after the user has successfully signed in."
    param :name, :string, "The display name chosen by the user"
    source "Welcome, {name}"
  end
end
```

Calling a generated message function returns a `%Translatable.Message{}` token,
not rendered text. Rendering happens through a runtime backend:

```elixir
MyApp.IsTranslatable.translate(MyAppWeb.LoginMessages.greeting("Troy"), to: "es")
```

The runtime backend owns provider order, language lists, fallbacks,
interpolation, and bundle layout:

```elixir
defmodule MyApp.IsTranslatable do
  use Translatable.Runtime

  source_lang "en"
  langs ["en", "es", "de"]

  fallback "es-MX", to: ["es", "en"]

  bundle_everything filename: "my_app"

  provider Translatable.Provider.Json
  provider Translatable.Provider.Source
end
```

## Artifacts

The workflow uses four committed artifact families and one build-only family.

`priv/translatable/source`
: Compact source manifests. These store message keys and hashes and should be
  committed.

`_build/<env>/translatable/extract`
: Full source extracts. These contain source strings, translator notes,
  parameters, pre-translated strings, and source locations. They are intended
  for upload or transform workflows and should normally not be committed.

`priv/translatable/runtime`
: Packaged runtime bundles. These are loaded by `Translatable.Provider.Json` and
  should be committed.

`priv/translatable/lock`
: Translation lock files. These record which source and definition hashes the
  runtime bundles cover and should be committed.

`priv/translatable/lock/*["deferred"]`
: Optional deferral metadata. This exists only while a source change has been
  intentionally allowed to ship before translated strings are complete.

## Workflow

### Extract

Run extraction after source messages change:

```bash
mix translatable.extract
```

Extraction writes:

* source manifests to `priv/translatable/source`
* full extracts to `_build/<env>/translatable/extract`

The committed source manifest lets validation detect whether message source has
changed since extraction.

### Translate

The full extract is the canonical input for adapters and TMS upload scripts. The
default exchange format is JSON. Other formats such as XLIFF can be added later,
but JSON is the source of truth for this workflow because it can carry all
message metadata.

If a translation service can preserve only one hash per string, adapter authors
should prefer `definition_hash`. It covers the source text, source language,
translator note, translatability flag, and parameter contract. The canonical
JSON format should preserve `source_hash`, `params_hash`, and `definition_hash`
when possible.

### Package

Run packaging after translated input is available:

```bash
mix translatable.package _build/dev/translatable/pendulum_translations.json
```

Packaging reads one or more translation input files, checks hashes, and writes:

* runtime bundles to `priv/translatable/runtime`
* lock files to `priv/translatable/lock`

If the same message key appears in multiple translation inputs with different
content, packaging fails rather than choosing an arbitrary winner.

The package input contract is documented in
[`docs/package-input.md`](package-input.md), with a JSON Schema at
[`docs/schemas/package-input.schema.json`](schemas/package-input.schema.json).

### Validate

Run validation in CI and before commits:

```bash
mix translatable.validate
```

Validation checks backend configuration, providers, current message definitions,
source manifests, locks, runtime bundles, interpolation bindings, orphaned
messages, and deferrals.

### Defer

Use deferral when a source change is safe to ship before translated strings are
available:

```bash
mix translatable.defer --reason feature_flagged --link https://github.com/my/app/issues/123
```

Deferral requires the source manifest to be current. It records pending hashes in
the lock file and writes source-language fallbacks into runtime bundles so
production still has renderable strings. A later package run removes matching
deferrals automatically.

## Bundle Strategies

Bundles control file layout only. They do not change message keys.

### Everything

```elixir
bundle_everything filename: "my_app"
```

Writes one source, extract, runtime, and lock file.

### Per Module

```elixir
bundle_per_module path: "my_app"
```

Writes one shard per message module and a `manifest.json` beside those shards.
The runtime JSON provider reads the runtime manifest in releases.

### Custom

```elixir
bundle_custom path: "my_app" do
  default filename: "my_app.json"

  bundle filename: "web.json",
    includes: submodules(of: MyAppWeb)

  bundle filename: "game.json",
    includes: [
      submodules(of: MyApp.Game.Command),
      submodules(of: MyApp.Game.Continuation)
    ]
end
```

The default bundle is required and receives unmatched modules. Explicit bundles
route by matcher specificity. Equal specificity ties and duplicate filenames are
errors.

## Runtime Providers

Providers return raw translated text. Interpolation is handled separately by the
runtime backend.

Provider order matters. If a provider knows about a message key, it owns every
language variant for that key. Later providers are not mixed in for missing
languages from the same key.

Common setups:

* `Translatable.Provider.Json` for packaged runtime bundles.
* `Translatable.Provider.Source` for development/test fallback or pretranslated
  strings stored in source modules.
* `Translatable.Provider.PO` or custom providers for migration paths.

## Roadmap

Near-term documentation and workflow work:

* Better validation output, including JSON output for CI.
* A documented TMS adapter workflow once a provider and current API are chosen.
* XLIFF package input support after the JSON schema is stable.
* Internal dogfooding for Mix task output using simple interpolation.

Later architecture work:

* Backend delegation for projects with distinct translation policies.
* Plug helper polish around request language selection.
* More provider validation hooks for duplicate keys and malformed resources.
