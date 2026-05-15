# Package Input JSON

`mix translatable.package` consumes translated JSON using the
`translatable.translations.v1` format. This is the canonical exchange format
for moving Translatable strings through a translation management system.

The JSON Schema is available at
[`docs/schemas/package-input.schema.json`](schemas/package-input.schema.json),
and a complete example is available at
[`examples/package-input.json`](../examples/package-input.json).

## Shape

```json
{
  "format": "translatable.translations.v1",
  "messages": [
    {
      "key": "my_app:MyApp.Messages.greeting",
      "source_hash": "sha256:...",
      "params_hash": "sha256:...",
      "definition_hash": "sha256:...",
      "translations": [
        { "lang": "es", "text": "Hola {name}" }
      ]
    }
  ]
}
```

Each message may also include the richer metadata emitted by
`mix translatable.extract`, such as `source`, `translator_note`, `params`, and
`location`. Translatable preserves a permissive schema here so adapters can
round-trip all source metadata through services that support it.

## Hashes

Package input must preserve all three hashes:

* `source_hash` changes when source language or source text changes.
* `params_hash` changes when the parameter contract changes.
* `definition_hash` changes when any translator-relevant definition metadata
  changes, including the source text, source language, translator note,
  translatability flag, and parameter contract.

If a translation service can preserve only one hash per string, prefer
`definition_hash`. It is the best single signal that the translation unit needs
translator attention. The package task still expects all three hashes in its
input so CI can distinguish stale source text from stale metadata.

## Duplicates

Within one package input:

* message keys must be unique
* translation language codes must be unique per message

When multiple input files are supplied to `mix translatable.package`, the same
message key may appear in more than one file only if the message objects are
identical. Any ambiguous overlap is an error.
