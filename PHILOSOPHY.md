# Philosophy

Translatable was born from me working on a personal benchmark project between paying jobs. I wanted to create a system that represented some of the best I could produce, and given my recent experience, that meant localisation (l10n) support: Externalised strings, language bundles for string packaging, and use of ICU for accurate representations across languages. Looking at the Elixir ecosystem at the time (early 2026), localisation seemed to be centralised around `gettext`, which is fine but has a number of European-language-shaped gaps in functionality. I saw that a mature CLDR project already existed in Elixir and so built my project around CLDR and the ICU message format.

## The problem

One problem that I've learned the hard way is that string externalisation is easy enough to set up or migrate, but difficult to maintain without rigour.

* If you modify a string, how do you ensure that all of the translations are updated with the latest version?
* If you get an updated translation for one language, how do you ensure that it corresponds to the latest version of the source string?
* If you add a new message, how do you ensure that you get translations before releasing the feature including the new message?
* If you are missing some translations, do the missing languages always fall back to the source language, or do they error?
* If your translation workflow includes support for specifying notes for translators, where do those notes live within your bundling?

In a more practical sense, if creating a new externalisable string requires creating a unique key, adding the default message to the main bundle, and then referencing the external string from your user-facing code... how often will a programmer simply inline a string to create a new feature, promising themself that they will externalise the string before they are done? How do you ensure that strings are externalised consistently?

## A better default

This library lives on the philosophy that programmers work best in code, and we can generate everything else. The Translatable library lets you declare externalised strings in a namespaced module including the source text, but also including translator notes, descriptions of any interpolated parameters, and known good translations. Or just a "don't translate" marker so wordmarks can live alongside other externalisable strings rather than being inline strings that need justification every six months. The important point is that it's nearly as easy to add a new Translatable string as it is to add a new inline string, and code review now has something concrete to trigger questions like "Are the translator notes appropriate?"

This library is the distillation of my experience working with externalisable strings and translation workflows. It is released under the MIT license because I want software to be easier to use, and I believe access to software in someone's native language has the potential to make people's lives better, and an easy-to-use, robust translation workflow should be the default rather than the exception. If you like any of the ideas in this library, please take them and adapt them with my blessing. If this library doesn't quite work for you (and you're using Elixir), raise an issue on the repository and we can discuss whether your specific workflow is within the scope of this library, or if some alternative may be more appropriate.

Laimingo kelio.

-Troy
