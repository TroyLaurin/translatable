defmodule Translatable.Validate.Reporter do
  @moduledoc """
  Formats `Translatable.Validate` issues for CLI output.

  The text format is intended for humans and avoids noisy implementation
  details such as hashes unless no friendlier explanation is available. The JSON
  format preserves the exact structured issues for CI systems and tooling.
  """

  alias Translatable.Validate.Reporter.Issue
  alias Translatable.Validation.Issue, as: ValidationIssue

  @spec text([ValidationIssue.t()]) :: String.t()
  def text(issues) do
    issues
    |> ordered_issues()
    |> Enum.map(&to_report_issue/1)
    |> group_text_issues()
    |> Enum.map_join("\n\n", &text_issue/1)
  end

  @spec json([ValidationIssue.t()]) :: String.t()
  def json(issues) do
    issues
    |> ordered_issues()
    |> Enum.map(&to_report_issue/1)
    |> Enum.map(&issue_to_json/1)
    |> then(&%{"issues" => &1})
    |> Jason.encode!(pretty: true)
  end

  defp ordered_issues(issues), do: Enum.sort_by(issues, &issue_sort_key/1)

  defp issue_sort_key(%ValidationIssue{} = issue) do
    {
      severity_order(issue.severity),
      code_order(issue.code),
      issue.context[:key] || "",
      issue.context[:lang] || "",
      issue.context[:path] || ""
    }
  end

  defp severity_order(:error), do: 0
  defp severity_order(:warning), do: 1
  defp severity_order(_severity), do: 2

  defp code_order(:missing_backend), do: 10
  defp code_order(:backend_not_loaded), do: 11
  defp code_order(:invalid_backend), do: 12
  defp code_order(:missing_runtime_callback), do: 13
  defp code_order(:invalid_source_lang), do: 14
  defp code_order(:invalid_langs), do: 15
  defp code_order(:source_lang_not_listed), do: 16
  defp code_order(:duplicate_langs), do: 17
  defp code_order(:missing_bundle), do: 18
  defp code_order(:invalid_providers), do: 19
  defp code_order(:invalid_provider), do: 20
  defp code_order(:provider_prepare_failed), do: 21
  defp code_order(:invalid_interpolator), do: 22
  defp code_order(:missing_source_manifest), do: 30
  defp code_order(:invalid_source_manifest), do: 31
  defp code_order(:stale_hash), do: 32
  defp code_order(:missing_artifact_message), do: 33
  defp code_order(:missing_lock), do: 40
  defp code_order(:invalid_lock), do: 41
  defp code_order(:missing_runtime_bundle), do: 42
  defp code_order(:invalid_runtime_bundle), do: 43
  defp code_order(:missing_runtime_translation), do: 44
  defp code_order(:missing_runtime_message), do: 45
  defp code_order(:invalid_runtime_translation), do: 50
  defp code_order(:invalid_runtime_message), do: 51
  defp code_order(:invalid_bindings), do: 52
  defp code_order(:deferred_stale_hash), do: 60
  defp code_order(:deferred_artifact_message), do: 61
  defp code_order(:deferred_runtime_translation), do: 62
  defp code_order(:deferred_runtime_message), do: 63
  defp code_order(:orphan_source_manifest_message), do: 70
  defp code_order(:orphan_lock_message), do: 71
  defp code_order(:orphan_runtime_message), do: 72
  defp code_order(_code), do: 999

  defp to_report_issue(%ValidationIssue{} = issue) do
    %Issue{
      severity: issue.severity,
      code: issue.code,
      problem: problem(issue),
      fix: fix(issue),
      message: issue.message,
      context: issue.context,
      languages: issue_languages(issue)
    }
  end

  defp text_issue(%Issue{} = issue) do
    [
      "#{issue.severity |> Atom.to_string() |> String.upcase()} #{issue.code}",
      detail("Message", issue.context[:key]),
      "  Problem: #{issue.problem}",
      detail("Language(s)", formatted_languages(issue.languages)),
      detail("Path", issue.context[:path]),
      "  Fix: #{issue.fix}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp detail(_label, nil), do: nil
  defp detail(label, value), do: "  #{label}: #{value}"

  defp group_text_issues(issues) do
    {groupable, single} = Enum.split_with(issues, &groupable_text_issue?/1)

    grouped =
      groupable
      |> Enum.group_by(&text_group_key/1)
      |> Enum.map(fn {_key, issues} ->
        [first | _rest] = issues

        languages =
          issues
          |> Enum.flat_map(& &1.languages)
          |> Enum.uniq()
          |> Enum.sort()

        %{first | languages: languages}
      end)

    Enum.sort_by(single ++ grouped, &report_issue_sort_key/1)
  end

  defp groupable_text_issue?(%Issue{code: code}) do
    code in [:missing_runtime_translation, :deferred_runtime_translation, :invalid_bindings]
  end

  defp text_group_key(%Issue{} = issue) do
    {issue.severity, issue.code, issue.context[:key], issue.problem, issue.fix}
  end

  defp report_issue_sort_key(%Issue{} = issue) do
    {
      severity_order(issue.severity),
      code_order(issue.code),
      issue.context[:key] || "",
      List.first(issue.languages) || "",
      issue.context[:path] || ""
    }
  end

  defp formatted_languages([]), do: nil

  defp formatted_languages(languages) do
    languages
    |> Enum.take(10)
    |> Kernel.++(if length(languages) > 10, do: ["..."], else: [])
    |> Enum.join(", ")
  end

  defp issue_languages(%ValidationIssue{context: %{lang: lang}}) when is_binary(lang), do: [lang]
  defp issue_languages(%ValidationIssue{context: %{label: lang}}) when is_binary(lang), do: [lang]
  defp issue_languages(_issue), do: []

  defp problem(%ValidationIssue{code: :missing_backend}),
    do: "no default Translatable backend is configured."

  defp problem(%ValidationIssue{code: :backend_not_loaded}),
    do: "the configured Translatable backend could not be loaded."

  defp problem(%ValidationIssue{code: :invalid_backend}),
    do: "the configured Translatable backend is not a module."

  defp problem(%ValidationIssue{code: :missing_runtime_callback}),
    do: "the backend does not expose the Translatable runtime callback."

  defp problem(%ValidationIssue{code: :invalid_source_lang}), do: "source_lang must be a string."

  defp problem(%ValidationIssue{code: :invalid_langs}),
    do: "langs must be a non-empty list of strings."

  defp problem(%ValidationIssue{code: :source_lang_not_listed}),
    do: "source_lang must also be listed in langs."

  defp problem(%ValidationIssue{code: :duplicate_langs}), do: "langs contains duplicate entries."

  defp problem(%ValidationIssue{code: :missing_bundle}),
    do: "the backend does not configure a Translatable bundle."

  defp problem(%ValidationIssue{code: :invalid_provider}),
    do: "a configured provider is invalid or does not implement lookup/3."

  defp problem(%ValidationIssue{code: :invalid_providers}),
    do: "providers must be a non-empty list."

  defp problem(%ValidationIssue{code: :provider_prepare_failed}),
    do: "a configured provider failed its startup/preparation check."

  defp problem(%ValidationIssue{code: :invalid_interpolator}),
    do: "the configured interpolator is invalid or does not implement interpolate/4."

  defp problem(%ValidationIssue{code: :missing_source_manifest}),
    do: "the source manifest is missing."

  defp problem(%ValidationIssue{code: :invalid_source_manifest}),
    do: "the source manifest could not be read as valid JSON."

  defp problem(%ValidationIssue{code: :missing_lock}), do: "the package lock file is missing."

  defp problem(%ValidationIssue{code: :invalid_lock}),
    do: "the package lock file could not be read as valid JSON."

  defp problem(%ValidationIssue{code: :missing_runtime_bundle}),
    do: "the runtime bundle is missing."

  defp problem(%ValidationIssue{code: :invalid_runtime_bundle}),
    do: "the runtime bundle could not be read as valid JSON."

  defp problem(%ValidationIssue{code: :stale_hash, context: %{artifact: artifact, field: field}}) do
    "#{artifact} has stale #{field}; source metadata changed after this artifact was written."
  end

  defp problem(%ValidationIssue{
         code: :deferred_stale_hash,
         context: %{artifact: artifact, field: field}
       }) do
    "#{artifact} has stale #{field}, but this message has an active deferral."
  end

  defp problem(%ValidationIssue{code: :missing_artifact_message, context: %{artifact: artifact}}) do
    "the message is missing from #{artifact}."
  end

  defp problem(%ValidationIssue{code: :deferred_artifact_message, context: %{artifact: artifact}}) do
    "the message is missing from #{artifact}, but this message has an active deferral."
  end

  defp problem(%ValidationIssue{code: :orphan_source_manifest_message}) do
    "the source manifest contains a message that no longer exists in source."
  end

  defp problem(%ValidationIssue{code: :orphan_lock_message}) do
    "the lock file contains a message that no longer exists in source."
  end

  defp problem(%ValidationIssue{code: :orphan_runtime_message}) do
    "the runtime bundle contains a message that no longer exists in source."
  end

  defp problem(%ValidationIssue{code: :invalid_runtime_translation}),
    do: "a runtime translation value is not a string."

  defp problem(%ValidationIssue{code: :missing_runtime_translation}),
    do: "a runtime translation is missing for a configured language."

  defp problem(%ValidationIssue{code: :deferred_runtime_translation}) do
    "a runtime translation is missing for a configured language, but this message has an active deferral."
  end

  defp problem(%ValidationIssue{code: :invalid_runtime_message}) do
    "the runtime bundle entry for this message is not a language-to-text map."
  end

  defp problem(%ValidationIssue{code: :missing_runtime_message}),
    do: "the message is missing from the runtime bundle."

  defp problem(%ValidationIssue{code: :deferred_runtime_message}),
    do: "the message is missing from the runtime bundle, but this message has an active deferral."

  defp problem(%ValidationIssue{code: :invalid_bindings}),
    do: "the text does not match the message parameter contract."

  defp problem(%ValidationIssue{message: message}), do: message

  defp fix(%ValidationIssue{code: :missing_backend}),
    do: "configure a default backend in config.exs."

  defp fix(%ValidationIssue{code: code})
       when code in [
              :backend_not_loaded,
              :invalid_backend,
              :missing_runtime_callback,
              :invalid_source_lang,
              :invalid_langs,
              :source_lang_not_listed,
              :duplicate_langs,
              :missing_bundle,
              :invalid_provider,
              :invalid_providers,
              :provider_prepare_failed,
              :invalid_interpolator
            ] do
    "update the Translatable backend configuration."
  end

  defp fix(%ValidationIssue{code: code})
       when code in [
              :missing_source_manifest,
              :invalid_source_manifest,
              :stale_hash,
              :missing_artifact_message,
              :orphan_source_manifest_message
            ] do
    "run `mix translatable.extract`."
  end

  defp fix(%ValidationIssue{code: :missing_runtime_translation}) do
    "make sure your translation input contains the required languages and run `mix translatable.package`."
  end

  defp fix(%ValidationIssue{code: code})
       when code in [
              :missing_lock,
              :invalid_lock,
              :missing_runtime_bundle,
              :invalid_runtime_bundle,
              :invalid_runtime_translation,
              :invalid_runtime_message,
              :missing_runtime_message,
              :orphan_lock_message,
              :orphan_runtime_message
            ] do
    "run `mix translatable.package` with current translation input."
  end

  defp fix(%ValidationIssue{code: code})
       when code in [
              :deferred_stale_hash,
              :deferred_artifact_message,
              :deferred_runtime_translation,
              :deferred_runtime_message
            ] do
    "package translated strings when they are available; the current gap is recorded as deferred."
  end

  defp fix(%ValidationIssue{code: :invalid_bindings}) do
    "fix the source or translated text so its placeholders match the declared parameters."
  end

  defp fix(_issue), do: "inspect the issue details and update Translatable artifacts."

  defp issue_to_json(%Issue{} = issue) do
    %{
      "severity" => Atom.to_string(issue.severity),
      "code" => Atom.to_string(issue.code),
      "message" => issue.message,
      "problem" => issue.problem,
      "fix" => issue.fix,
      "languages" => issue.languages,
      "context" => stringify_context(issue.context)
    }
  end

  defp stringify_context(context) do
    Map.new(context, fn {key, value} -> {Atom.to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value), do: value
end
