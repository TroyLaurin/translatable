defmodule Translatable.Runtime.Messages do
  @moduledoc """
  Translatable messages for runtime translation failures.

  These messages are intended for developer/programmer-facing diagnostics. They
  let host applications render Translatable's own errors through the same
  translation pipeline when that is useful.
  """

  use Translatable, application: :translatable

  defmsg module_not_translatable(module) do
    param :module, :string, "The module that was expected to implement the Translatable behaviour"
    source "The module {module} does not implement the Translatable behaviour"
  end

  defmsg unknown_message(module, name) do
    param :module, :string, "The module that was expected to define the message"
    param :name, :string, "The local message name that could not be found"
    source "The module {module} does not define the translatable message {name}"
  end

  defmsg invalid_translatable_callback(module, result) do
    param :module, :string, "The module with an invalid Translatable callback"
    param :result, :string, "The unexpected callback result"
    source "The module {module} returned an invalid Translatable callback result: {result}"
  end

  defmsg invalid_lang(lang) do
    param :lang, :string, "The invalid lang option value"
    source "Translatable languages must be strings, got {lang}"
  end

  defmsg missing_lang(), as: "Translatable runtime translation requires an explicit language"

  defmsg missing_translation(key) do
    param :key, :string, "The exported translatable message key"
    source "No translation was found for {key}"
  end

  defmsg translation_failed(reason) do
    param :reason, :string, "The runtime translation failure reason"
    source "Unable to translate message: {reason}"
  end
end
