defmodule TranslatableTest.Cldr do
  @moduledoc false

  use Cldr,
    default_locale: "en",
    locales: ["en"],
    providers: [Cldr.Number, Cldr.Message]
end
