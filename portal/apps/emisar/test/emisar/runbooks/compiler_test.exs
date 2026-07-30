defmodule Emisar.Runbooks.CompilerTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Catalog, Fixtures}
  alias Emisar.Runbooks.Compiler

  @pack_hash "sha256:" <> String.duplicate("a", 64)

  setup do
    {_user, account, subject} = Fixtures.Subjects.owner_subject()
    %{account: account, subject: subject}
  end

  test "freezes exact trusted targets and redacts sensitive inputs", %{
    account: account,
    subject: subject
  } do
    runner =
      trusted_runner(account, subject, args: [arg("token", "string", sensitive: true)])

    definition =
      definition(runner.group,
        inputs: [input("token", sensitive: true)],
        args: %{"token" => %{"source" => "input", "ref" => "token"}}
      )

    assert {:ok, compiled} = Compiler.compile(definition, %{"token" => "secret"}, subject)
    assert Jason.decode!(compiled.inputs_raw) == %{"token" => "secret"}
    assert compiled.sensitive_input_names == ["token"]

    assert %{
             "inputs" => %{"token" => "[REDACTED]"},
             "total_items" => 1,
             "stages" => [%{"items" => [public_item]}]
           } = compiled.plan

    assert {:ok, runner_ref} = Emisar.Runners.public_ref(runner)
    assert public_item["runner_ref"] == runner_ref
    assert public_item["pack_ref"] == "linux-core@1.4.2/" <> @pack_hash
    assert public_item["args"] == %{"token" => "[REDACTED]"}

    assert [%{args_raw: raw, args_sha256: digest}] = compiled.items
    assert Jason.decode!(raw) == %{"token" => "secret"}
    assert digest == Emisar.Crypto.hash_hex(raw)
    refute inspect(compiled.plan) =~ "secret"
  end

  test "rejects a literal for a sensitive action argument", %{
    account: account,
    subject: subject
  } do
    runner =
      trusted_runner(account, subject, args: [arg("token", "string", sensitive: true)])

    definition =
      definition(runner.group,
        args: %{"token" => %{"source" => "literal", "value" => "secret"}}
      )

    assert {:error, issues} = Compiler.compile(definition, %{}, subject)

    assert Enum.map(issues, &{&1.code, &1.path}) == [
             {"invalid_binding", "/stages/0/steps/0/args/token"}
           ]
  end

  test "omits a missing optional input bound to an optional action argument", %{
    account: account,
    subject: subject
  } do
    runner =
      trusted_runner(account, subject, args: [arg("note", "string", required: false)])

    definition =
      definition(runner.group,
        inputs: [input("note", required: false)],
        args: %{"note" => %{"source" => "input", "ref" => "note"}}
      )

    assert {:ok, compiled} = Compiler.compile(definition, %{}, subject)
    assert Jason.decode!(compiled.inputs_raw) == %{}
    assert [%{args_raw: raw}] = compiled.items
    assert Jason.decode!(raw) == %{}
    assert get_in(compiled.plan, ["stages", Access.at(0), "items", Access.at(0), "args"]) == %{}
  end

  test "rejects a missing optional input bound to a required action argument", %{
    account: account,
    subject: subject
  } do
    runner = trusted_runner(account, subject, args: [arg("note", "string", required: true)])

    definition =
      definition(runner.group,
        inputs: [input("note", required: false)],
        args: %{"note" => %{"source" => "input", "ref" => "note"}}
      )

    assert {:error, issues} = Compiler.compile(definition, %{}, subject)

    assert Enum.map(issues, &{&1.code, &1.path}) == [
             {"invalid_binding", "/stages/0/steps/0/args/note"}
           ]
  end

  test "reports unknown targets at the authoring path", %{subject: subject} do
    definition = definition("missing-group")

    assert {:error, [issue]} = Compiler.compile(definition, %{}, subject)
    assert issue.code == "unknown_target"
    assert issue.path == "/stages/0/steps/0/targets"
  end

  test "fails closed for signature-enforcing runners", %{account: account, subject: subject} do
    runner = trusted_runner(account, subject, enforce_signatures: true)

    assert {:error, [issue]} =
             runner.group
             |> definition()
             |> Compiler.compile(%{}, subject)

    assert issue.code == "signed_runbook_unsupported"
    assert issue.path == "/stages/0/steps/0/targets"
  end

  test "requires the selected pack to be trusted and deployed", %{
    account: account,
    subject: subject
  } do
    runner = trusted_runner(account, subject)

    definition =
      runner.group
      |> definition()
      |> put_in(
        ["stages", Access.at(0), "steps", Access.at(0), "pack", "id"],
        "missing-pack"
      )

    assert {:error, [issue]} = Compiler.compile(definition, %{}, subject)
    assert issue.code == "pack_unavailable"
    assert issue.path == "/stages/0/steps/0/pack"
  end

  test "rejects waits for actions that are not low-risk reads", %{
    account: account,
    subject: subject
  } do
    runner = trusted_runner(account, subject, risk: "high")

    wait = %{
      "interval_seconds" => 5,
      "timeout_seconds" => 20,
      "max_attempts" => 3
    }

    assert {:error, [issue]} =
             runner.group
             |> definition(wait: wait)
             |> Compiler.compile(%{}, subject)

    assert issue.code == "invalid_definition"
    assert issue.path == "/stages/0/steps/0/wait"
    assert issue.message == "Waits may repeat only low-risk read-only actions."
  end

  test "does not expose runners from another account", %{subject: subject} do
    {_user, other_account, other_subject} = Fixtures.Subjects.owner_subject()
    runner = trusted_runner(other_account, other_subject)

    assert {:error, [issue]} =
             runner.group
             |> definition()
             |> Compiler.compile(%{}, subject)

    assert issue.code == "unknown_target"
  end

  test "bounds only the selected deployment's hostile catalog rows", %{
    account: account,
    subject: subject
  } do
    selected = trusted_runner(account, subject, group: "selected")
    unrelated = trusted_runner(account, subject, group: "unrelated")
    add_catalog_noise(unrelated, "unrelated", 80)

    assert {:ok, _compiled} =
             selected.group
             |> definition()
             |> Compiler.compile(%{}, subject)

    add_catalog_noise(selected, "selected", 80)

    assert {:error, [issue]} =
             selected.group
             |> definition()
             |> Compiler.compile(%{}, subject)

    assert issue.code == "catalog_scope_too_large"
    assert issue.path == "/stages"
  end

  defp trusted_runner(account, subject, opts \\ []) do
    version = Keyword.get(opts, :version, "1.4.2")
    hash = Keyword.get(opts, :hash, @pack_hash)

    runner =
      Fixtures.Runners.create_runner(
        account_id: account.id,
        group: Keyword.get(opts, :group, "edge"),
        enforce_signatures: Keyword.get(opts, :enforce_signatures, false)
      )

    payload = %{
      "hostname" => runner.hostname,
      "version" => runner.runner_version,
      "labels" => runner.labels,
      "enforce_signatures" => runner.enforce_signatures,
      "packs" => %{"linux-core" => %{"version" => version, "hash" => hash}},
      "actions" => [
        %{
          "id" => "linux.uptime",
          "pack_id" => "linux-core",
          "title" => "Uptime",
          "kind" => "exec",
          "risk" => Keyword.get(opts, :risk, "low"),
          "summary" => "Reports uptime",
          "description" => "Reports uptime",
          "side_effects" => [],
          "args" => Keyword.get(opts, :args, []),
          "examples" => [],
          "search_terms" => []
        }
      ]
    }

    payload =
      if runner.enforce_signatures,
        do: Map.put(payload, "max_attestation_age_seconds", 86_400),
        else: payload

    assert {:ok, runner} = Catalog.observe_state(runner, payload)

    {:ok, versions} = Catalog.list_all_pack_versions_for_account(subject)

    Enum.each(versions, fn version ->
      if version.trust_state != :trusted do
        assert {:ok, _version} = Catalog.trust_pack_version(version.id, subject)
      end
    end)

    runner
  end

  defp definition(group, opts \\ []) do
    %{
      "schema_version" => 1,
      "context_markdown" => "Inspect the selected hosts.",
      "inputs" => Keyword.get(opts, :inputs, []),
      "stages" => [
        %{
          "id" => "inspect",
          "title" => "Inspect",
          "mode" => "parallel",
          "max_parallel" => 5,
          "steps" => [
            %{
              "id" => "uptime",
              "pack" => %{"id" => "linux-core"},
              "action" => "linux.uptime",
              "targets" => %{"refs" => ["group:" <> group]},
              "args" => Keyword.get(opts, :args, %{}),
              "outputs" => [],
              "success" => [],
              "wait" => Keyword.get(opts, :wait)
            }
          ]
        }
      ]
    }
  end

  defp add_catalog_noise(runner, prefix, count) do
    Enum.each(1..count, &create_catalog_noise(runner, prefix, &1))
  end

  defp create_catalog_noise(runner, prefix, position) do
    Fixtures.Catalog.create_action(
      runner: runner,
      action_id: "linux.#{prefix}_#{position}",
      pack_version: "1.4.2",
      pack_hash: @pack_hash
    )
  end

  defp input(id, opts) do
    %{
      "id" => id,
      "description" => "A test input",
      "type" => Keyword.get(opts, :type, "string"),
      "required" => Keyword.get(opts, :required, true),
      "sensitive" => Keyword.get(opts, :sensitive, false)
    }
  end

  defp arg(name, type, opts) do
    %{
      "name" => name,
      "type" => type,
      "required" => Keyword.get(opts, :required, true),
      "sensitive" => Keyword.get(opts, :sensitive, false)
    }
  end
end
