defmodule Translatable.Runtime.Error do
  @moduledoc """
  Helpers for turning runtime translation failure reasons into messages.
  """

  alias Translatable.Message
  alias Translatable.Runtime.Messages

  @spec message(term()) :: Message.t()
  def message({:module_not_translatable, module}) do
    Messages.module_not_translatable(inspect(module))
  end

  def message({:unknown_message, module, name}) do
    Messages.unknown_message(inspect(module), inspect(name))
  end

  def message({:invalid_translatable_callback, module, result}) do
    Messages.invalid_translatable_callback(inspect(module), inspect(result))
  end

  def message({:invalid_lang, lang}) do
    Messages.invalid_lang(inspect(lang))
  end

  def message(:missing_lang) do
    Messages.missing_lang()
  end

  def message({:missing_translation, key}) do
    Messages.missing_translation(key)
  end

  def message(reason) do
    Messages.translation_failed(inspect(reason))
  end
end
