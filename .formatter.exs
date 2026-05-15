locals_without_parens = [
  bundle_custom: 1,
  bundle_custom: 2,
  bundle_everything: 1,
  bundle_per_module: 1,
  bundle: 1,
  cldr_backend: 1,
  default: 1,
  defmsg: 2,
  dont_translate: 0,
  fallback: 2,
  interpolate_with: 1,
  interpolate_with: 2,
  langs: 1,
  param: 3,
  provider: 1,
  provider: 2,
  source: 1,
  source_lang: 1,
  submodules: 1,
  translated_to: 2,
  translatable_source: 1,
  translator_note: 1
]

[
  inputs: ["*.{ex,exs}", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]
