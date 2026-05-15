defmodule Translatable.Validate.ReporterTest do
  use ExUnit.Case, async: true

  alias Translatable.Validate.Reporter
  alias Translatable.Validation.Issue

  describe "text output" do
    test "backend configuration errors explain that the backend should be fixed" do
      issues = [
        issue(:error, :missing_backend,
          message: "No default Translatable backend is configured for :demo"
        ),
        issue(:error, :invalid_provider, message: "Demo.Provider must implement lookup/3")
      ]

      assert Reporter.text(issues) == """
             ERROR missing_backend
               Problem: no default Translatable backend is configured.
               Fix: configure a default backend in config.exs.

             ERROR invalid_provider
               Problem: a configured provider is invalid or does not implement lookup/3.
               Fix: update the Translatable backend configuration.\
             """
    end

    test "source manifest drift points developers at extract" do
      issues = [
        issue(:error, :stale_hash,
          message:
            "demo:Messages.hello has stale source_hash in source_manifest: expected sha256:new, got sha256:old",
          context: %{
            key: "demo:Messages.hello",
            field: "source_hash",
            artifact: :source_manifest
          }
        ),
        issue(:error, :missing_artifact_message,
          message: "demo:Messages.new is missing from source_manifest",
          context: %{key: "demo:Messages.new", artifact: :source_manifest}
        )
      ]

      assert Reporter.text(issues) == """
             ERROR stale_hash
               Message: demo:Messages.hello
               Problem: source_manifest has stale source_hash; source metadata changed after this artifact was written.
               Fix: run `mix translatable.extract`.

             ERROR missing_artifact_message
               Message: demo:Messages.new
               Problem: the message is missing from source_manifest.
               Fix: run `mix translatable.extract`.\
             """
    end

    test "lock and runtime gaps point developers at package" do
      issues = [
        issue(:error, :missing_lock,
          message: "Missing Translatable artifact: priv/translatable/lock/demo.json",
          context: %{path: "priv/translatable/lock/demo.json"}
        ),
        issue(:error, :missing_runtime_translation,
          message: "demo:Messages.hello is missing runtime translation for \"es\"",
          context: %{key: "demo:Messages.hello", lang: "es"}
        ),
        issue(:error, :missing_runtime_message,
          message: "demo:Messages.new is missing from runtime bundle",
          context: %{key: "demo:Messages.new"}
        )
      ]

      assert Reporter.text(issues) == """
             ERROR missing_lock
               Problem: the package lock file is missing.
               Path: priv/translatable/lock/demo.json
               Fix: run `mix translatable.package` with current translation input.

             ERROR missing_runtime_translation
               Message: demo:Messages.hello
               Problem: a runtime translation is missing for a configured language.
               Language(s): es
               Fix: make sure your translation input contains the required languages and run `mix translatable.package`.

             ERROR missing_runtime_message
               Message: demo:Messages.new
               Problem: the message is missing from the runtime bundle.
               Fix: run `mix translatable.package` with current translation input.\
             """
    end

    test "missing runtime translations group and truncate language lists" do
      issues =
        ~w(ar bg cs da de el es fi fr hr hu it ja ko)
        |> Enum.map(fn lang ->
          issue(:error, :missing_runtime_translation,
            message: "demo:Messages.hello is missing runtime translation for #{inspect(lang)}",
            context: %{key: "demo:Messages.hello", lang: lang}
          )
        end)

      assert Reporter.text(issues) == """
             ERROR missing_runtime_translation
               Message: demo:Messages.hello
               Problem: a runtime translation is missing for a configured language.
               Language(s): ar, bg, cs, da, de, el, es, fi, fr, hr, ...
               Fix: make sure your translation input contains the required languages and run `mix translatable.package`.\
             """
    end

    test "deferred gaps are warnings with asynchronous translation guidance" do
      issues = [
        issue(:warning, :deferred_artifact_message,
          message: "demo:Messages.hello is missing from lock but is deferred",
          context: %{key: "demo:Messages.hello", artifact: :lock}
        ),
        issue(:warning, :deferred_runtime_message,
          message: "demo:Messages.hello is missing from runtime bundle but is deferred",
          context: %{key: "demo:Messages.hello"}
        )
      ]

      assert Reporter.text(issues) == """
             WARNING deferred_artifact_message
               Message: demo:Messages.hello
               Problem: the message is missing from lock, but this message has an active deferral.
               Fix: package translated strings when they are available; the current gap is recorded as deferred.

             WARNING deferred_runtime_message
               Message: demo:Messages.hello
               Problem: the message is missing from the runtime bundle, but this message has an active deferral.
               Fix: package translated strings when they are available; the current gap is recorded as deferred.\
             """
    end

    test "malformed runtime translations point at parameter contracts" do
      issues = [
        issue(:error, :invalid_runtime_translation,
          message: "demo:Messages.hello has non-string runtime translation for \"es\": 123",
          context: %{key: "demo:Messages.hello", lang: "es"}
        ),
        issue(:error, :invalid_bindings,
          message: "demo:Messages.hello es references undeclared parameter :missing",
          context: %{key: "demo:Messages.hello", label: "es"}
        )
      ]

      assert Reporter.text(issues) == """
             ERROR invalid_runtime_translation
               Message: demo:Messages.hello
               Problem: a runtime translation value is not a string.
               Language(s): es
               Fix: run `mix translatable.package` with current translation input.

             ERROR invalid_bindings
               Message: demo:Messages.hello
               Problem: the text does not match the message parameter contract.
               Language(s): es
               Fix: fix the source or translated text so its placeholders match the declared parameters.\
             """
    end

    test "orphaned artifacts describe stale files" do
      issues = [
        issue(:warning, :orphan_source_manifest_message,
          message:
            "demo:Messages.old is present in priv/translatable/source/demo.json but not current source",
          context: %{key: "demo:Messages.old", path: "priv/translatable/source/demo.json"}
        ),
        issue(:warning, :orphan_runtime_message,
          message:
            "demo:Messages.old is present in priv/translatable/runtime/demo.json but not current source",
          context: %{key: "demo:Messages.old", path: "priv/translatable/runtime/demo.json"}
        )
      ]

      assert Reporter.text(issues) == """
             WARNING orphan_source_manifest_message
               Message: demo:Messages.old
               Problem: the source manifest contains a message that no longer exists in source.
               Path: priv/translatable/source/demo.json
               Fix: run `mix translatable.extract`.

             WARNING orphan_runtime_message
               Message: demo:Messages.old
               Problem: the runtime bundle contains a message that no longer exists in source.
               Path: priv/translatable/runtime/demo.json
               Fix: run `mix translatable.package` with current translation input.\
             """
    end

    test "falls back to the internal message for unknown issue codes" do
      issues = [
        issue(:error, :future_problem,
          message: "Something new happened",
          context: %{key: "demo:Messages.hello"}
        )
      ]

      assert Reporter.text(issues) == """
             ERROR future_problem
               Message: demo:Messages.hello
               Problem: Something new happened
               Fix: inspect the issue details and update Translatable artifacts.\
             """
    end

    test "does not expose hashes from internal messages" do
      issues = [
        issue(:error, :stale_hash,
          message:
            "demo:Messages.hello has stale source_hash in source_manifest: expected sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, got sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          context: %{
            key: "demo:Messages.hello",
            field: "source_hash",
            artifact: :source_manifest
          }
        )
      ]

      refute Reporter.text(issues) =~ "sha256:"
    end
  end

  describe "json output" do
    test "renders public reporter issue shape" do
      issues = [
        issue(:error, :missing_runtime_translation,
          message: "demo:Messages.hello is missing runtime translation for \"es\"",
          context: %{key: "demo:Messages.hello", lang: "es"}
        )
      ]

      assert Jason.decode!(Reporter.json(issues)) == %{
               "issues" => [
                 %{
                   "severity" => "error",
                   "code" => "missing_runtime_translation",
                   "message" => "demo:Messages.hello is missing runtime translation for \"es\"",
                   "problem" => "a runtime translation is missing for a configured language.",
                   "fix" =>
                     "make sure your translation input contains the required languages and run `mix translatable.package`.",
                   "languages" => ["es"],
                   "context" => %{
                     "key" => "demo:Messages.hello",
                     "lang" => "es"
                   }
                 }
               ]
             }
    end

    test "stringifies atom context values" do
      issues = [
        issue(:error, :stale_hash,
          message: "stale",
          context: %{key: "demo:Messages.hello", artifact: :lock, field: "source_hash"}
        )
      ]

      assert %{"issues" => [%{"context" => context}]} = Jason.decode!(Reporter.json(issues))
      assert context["artifact"] == "lock"
      assert context["field"] == "source_hash"
    end
  end

  defp issue(severity, code, opts) do
    %Issue{
      severity: severity,
      code: code,
      message: Keyword.fetch!(opts, :message),
      context: Keyword.get(opts, :context, %{})
    }
  end
end
