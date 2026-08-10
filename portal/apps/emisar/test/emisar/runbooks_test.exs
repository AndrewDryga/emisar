defmodule Emisar.RunbooksTest do
  use Emisar.DataCase, async: true
  alias Ecto.Multi
  alias Emisar.{Approvals, Catalog}
  alias Emisar.Auth.Subject
  alias Emisar.Fixtures
  alias Emisar.MCPOperations
  alias Emisar.Repo
  alias Emisar.Runbooks
  alias Emisar.Runbooks.{ExecutionItem, ExecutionStage, RunbookExecution}
  alias Emisar.Runners
  alias Emisar.Runs

  @pack_hash Emisar.Fixtures.Catalog.pack_hash("linux-core-1.4.2")

  describe "definition_schema/0" do
    test "publishes the immutable v1 authoring schema" do
      schema = Runbooks.definition_schema()

      assert schema["$id"] == "https://emisar.dev/schemas/runbook-definition-v1.json"
      assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
    end
  end

  describe "definition_limit!/1" do
    test "carries the schema's definition byte budget" do
      assert Runbooks.definition_limit!(:max_definition_bytes) == 65_536
    end
  end

  describe "metadata_limit!/1" do
    test "publishes the row metadata ceilings in bytes, the unit a budget can be derived from" do
      assert Runbooks.metadata_limit!(:title_bytes) == 320
      assert Runbooks.metadata_limit!(:description_bytes) == 8_192
    end
  end

  describe "decode_definition_json/1" do
    test "round-trips one canonical definition" do
      definition = definition()
      encoded = Jason.encode!(definition)

      assert Runbooks.decode_definition_json(encoded) == {:ok, definition}
    end

    test "reports malformed JSON as one stable issue" do
      assert Runbooks.decode_definition_json("{") ==
               {:error,
                [%{code: "invalid_json", path: "", message: "Enter a valid JSON object."}]}
    end

    test "rejects a document past the definition byte limit" do
      limit = Runbooks.definition_limit!(:max_definition_bytes)
      oversized = String.duplicate("x", limit + 1)

      issue = %{
        code: "invalid_definition",
        path: "",
        message: "JSON exceeds the #{limit} byte limit."
      }

      assert Runbooks.decode_definition_json(oversized) == {:error, [issue]}
    end
  end

  describe "validate_definition/1" do
    test "returns a canonical definition unchanged" do
      definition = definition()

      assert Runbooks.validate_definition(definition) == {:ok, definition}
    end

    test "reports a stable code and path for a malformed canonical object" do
      assert {:error, issues} =
               Runbooks.validate_definition(%{"schema_version" => 1, "stages" => []})

      assert Enum.any?(issues, &(&1.code == "invalid_definition" and &1.path == "/stages"))
    end
  end

  describe "validate_draft_definition/1" do
    test "accepts an incomplete canonical draft that strict validation refuses" do
      draft = %{
        "schema_version" => 1,
        "context_markdown" => "",
        "inputs" => [],
        "stages" => []
      }

      assert Runbooks.validate_draft_definition(draft) == {:ok, draft}
      assert {:error, _issues} = Runbooks.validate_definition(draft)
    end
  end

  describe "definition_digest/1" do
    test "is a stable SHA-256 that ignores key order" do
      assert Runbooks.definition_digest(%{"a" => 1, "b" => "two"}) ==
               "f15bfc93d70801047473922f67fed863ecc7f82f0677ebb7122923aee81e0f97"

      assert Runbooks.definition_digest(%{"b" => "two", "a" => 1}) ==
               "f15bfc93d70801047473922f67fed863ecc7f82f0677ebb7122923aee81e0f97"
    end
  end

  describe "build_definition_v1/1" do
    test "canonicalizes a typed editor command into a definition this context accepts" do
      command = %{
        context_markdown: "Confirm the incident first.",
        inputs: [],
        stages: []
      }

      definition = Runbooks.build_definition_v1(command)

      assert definition["schema_version"] == 1
      assert definition["context_markdown"] == "Confirm the incident first."
      assert definition["stages"] == []
      assert Runbooks.validate_draft_definition(definition) == {:ok, definition}
    end
  end

  describe "sync_definition_argument/2" do
    test "lets the descriptor own the metadata while the operator keeps their binding" do
      typed = %{"name" => "path", "type" => "path", "required" => true}

      fresh = Runbooks.sync_definition_argument(typed, nil)

      assert fresh.name == "path"
      assert fresh.type == "path"
      assert fresh.required?
      assert fresh.source == "literal"

      existing = %{fresh | value: "/var/lib/postgresql"}
      sensitive = %{"name" => "path", "type" => "path", "required" => true, "sensitive" => true}

      synced = Runbooks.sync_definition_argument(sensitive, existing)

      # A now-sensitive argument can no longer carry a typed literal.
      assert synced.sensitive?
      assert synced.source == "input"
    end
  end

  describe "resolve_slug/2" do
    test "keeps the operator's candidate and derives one only when none was typed" do
      assert Runbooks.resolve_slug("Check database fleet", "db-health") == "db-health"
      assert Runbooks.resolve_slug("Check database fleet", nil) == "check-database-fleet"
      assert Runbooks.resolve_slug("Check database fleet", "  ") == "check-database-fleet"
    end
  end

  describe "runbook_filters/0" do
    test "carries the Runbooks table's filters" do
      assert Enum.map(Runbooks.runbook_filters(), & &1.name) == [:state]
    end
  end

  describe "list_runbooks/2" do
    test "lists one row per runbook and applies filters" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      never_published = create_runbook(subject, title: "Draft")

      live =
        subject |> create_runbook(title: "Published") |> Fixtures.Runbooks.publish_runbook()

      {_user, _account, other_subject} = Fixtures.Subjects.owner_subject()
      _other = create_runbook(other_subject, title: "Other")

      assert {:ok, runbooks, _metadata} =
               Runbooks.list_runbooks(subject, filter: [state: ["live"]])

      assert Enum.map(runbooks, & &1.id) == [live.id]
      refute never_published.id in Enum.map(runbooks, & &1.id)
    end

    test "a runbook carrying unpublished changes over a live release matches both states" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()

      live = subject |> create_runbook(slug: "alpha") |> Fixtures.Runbooks.publish_runbook()
      revised = put_in(definition(), ["context_markdown"], "Inspect twice.")
      assert {:ok, edited} = save_draft(live, %{"draft_definition" => revised}, subject)

      assert {:ok, [matched_live], _metadata} =
               Runbooks.list_runbooks(subject, filter: [state: ["live"]])

      assert {:ok, [matched_draft], _metadata} =
               Runbooks.list_runbooks(subject, filter: [state: ["draft"]])

      assert matched_live.id == edited.id
      assert matched_draft.id == edited.id
    end

    test "lists every runbook in the account, ordered by title" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      beta = create_runbook(subject, slug: "beta", title: "Beta")
      alpha = create_runbook(subject, slug: "alpha", title: "Alpha")

      assert {:ok, runbooks, metadata} = Runbooks.list_runbooks(subject)
      assert Enum.map(runbooks, & &1.id) == [alpha.id, beta.id]
      assert metadata.count == 2
    end

    test "another account's runbook with the same slug stays out of the list" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      mine = create_runbook(subject, slug: "shared")
      {_user, _account, other_subject} = Fixtures.Subjects.owner_subject()
      _theirs = create_runbook(other_subject, slug: "shared")

      assert {:ok, runbooks, _metadata} = Runbooks.list_runbooks(subject)
      assert Enum.map(runbooks, & &1.id) == [mine.id]
    end

    test "denies a principal without view permission" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      assert Runbooks.list_runbooks(Subject.for_runner(runner, account)) ==
               {:error, :unauthorized}
    end
  end

  describe "definition_diff/2" do
    test "reports the changed lines between two definitions and nothing for a metadata-only save" do
      definition = definition()
      changed = put_in(definition, ["context_markdown"], "Inspect twice.")

      assert Runbooks.definition_diff(definition, definition) ==
               %Runbooks.DefinitionDiff{hunks: [], truncated?: false}

      assert %Runbooks.DefinitionDiff{hunks: [hunk]} =
               Runbooks.definition_diff(definition, changed)

      assert Enum.any?(hunk, &match?({:ins, _line}, &1))
      assert Enum.any?(hunk, &match?({:del, _line}, &1))
    end
  end

  describe "risk_by_runbooks/2" do
    test "maps each runbook to the worst risk across its steps" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "database")
      Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      Fixtures.Catalog.create_action(runner: runner, action_id: "linux.reboot", risk: "critical")

      mixed =
        create_runbook(subject, definition: risk_definition(["linux.uptime", "linux.reboot"]))

      calm = create_runbook(subject, definition: risk_definition(["linux.uptime"]))

      assert Runbooks.risk_by_runbooks([mixed, calm], subject) ==
               {:ok, %{mixed.id => :critical, calm.id => :low}}
    end

    test "reads the live release, falling back to the draft while nothing is live" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "database")
      Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      Fixtures.Catalog.create_action(runner: runner, action_id: "linux.reboot", risk: "critical")

      never_published = create_runbook(subject, definition: risk_definition(["linux.reboot"]))

      live =
        subject
        |> create_runbook(definition: risk_definition(["linux.uptime"]))
        |> Fixtures.Runbooks.publish_runbook()

      assert {:ok, edited} =
               save_draft(
                 live,
                 %{"draft_definition" => risk_definition(["linux.reboot"])},
                 subject
               )

      assert Runbooks.risk_by_runbooks([never_published, edited], subject) ==
               {:ok, %{never_published.id => :critical, edited.id => :low}}
    end

    test "an unobserved step leaves the whole runbook unresolved" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "database")
      Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "critical")

      partial =
        create_runbook(subject, definition: risk_definition(["linux.uptime", "linux.reboot"]))

      # Nobody advertises linux.reboot — answering `critical` from the one step
      # we can resolve would understate a runbook whose rest is unknown.
      assert Runbooks.risk_by_runbooks([partial], subject) == {:ok, %{partial.id => nil}}
    end

    test "omits deleted and cross-account runbooks a caller still holds" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      deleted = create_runbook(subject) |> delete(subject)
      {_user, _account, other_subject} = Fixtures.Subjects.owner_subject()
      other = create_runbook(other_subject)

      assert Runbooks.risk_by_runbooks([deleted, other], subject) == {:ok, %{}}
    end

    test "denies a principal without view permission, including for an empty list" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      subject = Subject.for_runner(runner, account)
      {_user, _other_account, other_subject} = Fixtures.Subjects.owner_subject()
      runbook = create_runbook(other_subject)

      assert Runbooks.risk_by_runbooks([], subject) == {:error, :unauthorized}
      assert Runbooks.risk_by_runbooks([runbook], subject) == {:error, :unauthorized}
    end

    test "accepts a full batch and refuses anything larger or unbounded" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      runbook = create_runbook(subject)

      assert {:ok, _risks} = Runbooks.risk_by_runbooks(List.duplicate(runbook, 64), subject)

      assert Runbooks.risk_by_runbooks(List.duplicate(runbook, 65), subject) ==
               {:error, :too_many_runbooks}

      assert Runbooks.risk_by_runbooks(%{}, subject) == {:error, :too_many_runbooks}
    end
  end

  describe "list_model_visible_runbooks/1" do
    test "returns every live runbook and skips the never-published" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = trusted_runner(account, subject)

      live =
        subject
        |> create_runbook(slug: "alpha", definition: definition(runner.group))
        |> Fixtures.Runbooks.publish_runbook()

      _never_published =
        create_runbook(subject, slug: "beta", definition: definition(runner.group))

      assert {:ok, runbooks} = Runbooks.list_model_visible_runbooks(subject)
      assert Enum.map(runbooks, & &1.id) == [live.id]
    end

    test "an unpublished change never suppresses the release running behind it" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = trusted_runner(account, subject)

      live =
        subject
        |> create_runbook(slug: "alpha", definition: definition(runner.group))
        |> Fixtures.Runbooks.publish_runbook()

      revised = put_in(definition(runner.group), ["context_markdown"], "Inspect twice.")
      assert {:ok, edited} = save_draft(live, %{"draft_definition" => revised}, subject)

      assert {:ok, [visible]} = Runbooks.list_model_visible_runbooks(subject)
      assert visible.id == edited.id
      assert visible.live_version == 1
    end

    test "drops a live runbook once its pack trust is revoked" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = trusted_runner(account, subject)

      runbook =
        subject
        |> create_runbook(definition: definition(runner.group))
        |> Fixtures.Runbooks.publish_runbook()

      assert {:ok, [visible]} = Runbooks.list_model_visible_runbooks(subject)
      assert visible.id == runbook.id

      assert {:ok, [trusted]} = Catalog.list_all_pack_versions_for_account(subject)
      assert {:ok, _revoked} = Catalog.revoke_pack_version_trust(trusted.id, subject)

      assert Runbooks.list_model_visible_runbooks(subject) == {:ok, []}
    end

    test "denies a principal without view permission" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      assert Runbooks.list_model_visible_runbooks(Subject.for_runner(runner, account)) ==
               {:error, :unauthorized}
    end
  end

  describe "list_model_draft_runbooks/1" do
    test "returns every runbook carrying an unpublished change, available or not" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = trusted_runner(account, subject)

      live =
        subject
        |> create_runbook(slug: "working", definition: definition(runner.group))
        |> Fixtures.Runbooks.publish_runbook()

      revised = put_in(definition(runner.group), ["context_markdown"], "Inspect twice.")
      assert {:ok, edited} = save_draft(live, %{"draft_definition" => revised}, subject)

      assert {:ok, [draft]} = Runbooks.list_model_draft_runbooks(subject)
      assert draft.id == edited.id

      assert {:ok, [trusted]} = Catalog.list_all_pack_versions_for_account(subject)
      assert {:ok, _revoked} = Catalog.revoke_pack_version_trust(trusted.id, subject)

      assert {:ok, [still_visible]} = Runbooks.list_model_draft_runbooks(subject)
      assert still_visible.id == edited.id
    end

    test "excludes a runbook with nothing unpublished and another account's drafts" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      _shipped = subject |> create_runbook(slug: "shipped") |> Fixtures.Runbooks.publish_runbook()
      working = create_runbook(subject, slug: "working")

      {_other_user, _other_account, other_subject} = Fixtures.Subjects.owner_subject()
      _theirs = create_runbook(other_subject, slug: "theirs")

      assert {:ok, [draft]} = Runbooks.list_model_draft_runbooks(subject)
      assert draft.id == working.id
    end

    test "denies a principal without view permission" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      assert Runbooks.list_model_draft_runbooks(Subject.for_runner(runner, account)) ==
               {:error, :unauthorized}
    end
  end

  describe "fetch_model_visible_runbook/2" do
    test "returns the live runbook until its contract stops resolving" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = trusted_runner(account, subject)

      live =
        subject
        |> create_runbook(slug: "versioned", definition: definition(runner.group))
        |> Fixtures.Runbooks.publish_runbook()

      assert {:ok, fetched} = Runbooks.fetch_model_visible_runbook("versioned", subject)
      assert fetched.id == live.id

      assert {:ok, [trusted]} = Catalog.list_all_pack_versions_for_account(subject)
      assert {:ok, _revoked} = Catalog.revoke_pack_version_trust(trusted.id, subject)

      assert Runbooks.fetch_model_visible_runbook("versioned", subject) == {:error, :not_found}
    end

    test "hides never-published runbooks, unknown slugs, and another account's" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = trusted_runner(account, subject)

      _never_published =
        create_runbook(subject, slug: "draft-only", definition: definition(runner.group))

      _live =
        subject
        |> create_runbook(slug: "versioned", definition: definition(runner.group))
        |> Fixtures.Runbooks.publish_runbook()

      assert Runbooks.fetch_model_visible_runbook("draft-only", subject) == {:error, :not_found}
      assert Runbooks.fetch_model_visible_runbook("missing", subject) == {:error, :not_found}

      {_user, _account, other_subject} = Fixtures.Subjects.owner_subject()

      assert Runbooks.fetch_model_visible_runbook("versioned", other_subject) ==
               {:error, :not_found}
    end

    test "denies a principal without view permission" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      assert Runbooks.fetch_model_visible_runbook("any", Subject.for_runner(runner, account)) ==
               {:error, :unauthorized}
    end
  end

  describe "fetch_model_runbook_draft/2" do
    test "returns the unpublished change even when its target is unavailable" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = trusted_runner(account, subject)
      working = create_runbook(subject, slug: "working", definition: definition(runner.group))

      assert {:ok, fetched} = Runbooks.fetch_model_runbook_draft("working", subject)
      assert fetched.id == working.id

      assert {:ok, [trusted]} = Catalog.list_all_pack_versions_for_account(subject)
      assert {:ok, _revoked} = Catalog.revoke_pack_version_trust(trusted.id, subject)

      assert {:ok, still_readable} = Runbooks.fetch_model_runbook_draft("working", subject)
      assert still_readable.id == working.id
    end

    test "hides a runbook with nothing unpublished and another account's" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      _shipped = subject |> create_runbook(slug: "shipped") |> Fixtures.Runbooks.publish_runbook()
      _working = create_runbook(subject, slug: "working")

      assert Runbooks.fetch_model_runbook_draft("shipped", subject) == {:error, :not_found}

      {_other_user, _other_account, other_subject} = Fixtures.Subjects.owner_subject()

      assert Runbooks.fetch_model_runbook_draft("working", other_subject) == {:error, :not_found}
    end

    test "denies a principal without view permission" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      assert Runbooks.fetch_model_runbook_draft("any", Subject.for_runner(runner, account)) ==
               {:error, :unauthorized}
    end
  end

  describe "fetch_runbook_by_id/2" do
    test "returns an owned row and hides invalid, deleted, and cross-account ids" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      owned = create_runbook(subject)
      deleted = create_runbook(subject) |> delete(subject)
      {_user, _account, other_subject} = Fixtures.Subjects.owner_subject()
      other = create_runbook(other_subject)

      assert {:ok, fetched} = Runbooks.fetch_runbook_by_id(owned.id, subject)
      assert fetched.id == owned.id
      assert Runbooks.fetch_runbook_by_id("not-a-uuid", subject) == {:error, :not_found}
      assert Runbooks.fetch_runbook_by_id(deleted.id, subject) == {:error, :not_found}
      assert Runbooks.fetch_runbook_by_id(other.id, subject) == {:error, :not_found}
    end
  end

  describe "fetch_execution_by_id/2" do
    test "returns only executions visible through current account and runner scope" do
      fixture = mcp_execution_fixture()

      assert {:ok, fetched} =
               Runbooks.fetch_execution_by_id(fixture.execution_id, fixture.subject)

      assert fetched.id == fixture.execution_id

      assert Runbooks.fetch_execution_by_id("not-a-uuid", fixture.subject) ==
               {:error, :not_found}

      {_user, _account, other_subject} = Fixtures.Subjects.owner_subject()

      assert Runbooks.fetch_execution_by_id(fixture.execution_id, other_subject) ==
               {:error, :not_found}
    end

    test "hides an execution when current runner scope excludes one selected runner" do
      fixture = mcp_execution_fixture()

      fixture.account.id
      |> Fixtures.Memberships.fetch_membership(fixture.owner.actor.id)
      |> Fixtures.Memberships.force_runner_access(Emisar.Accounts.RunnerAccess.none())

      assert Runbooks.fetch_execution_by_id(fixture.execution_id, fixture.subject) ==
               {:error, :not_found}

      assert Runbooks.fetch_execution_result(fixture.execution_id, fixture.subject) ==
               {:error, :not_found}
    end
  end

  describe "fetch_execution_recovery_identity/2" do
    test "returns account-scoped provenance after current runner scope narrows" do
      fixture = mcp_execution_fixture()

      fixture.account.id
      |> Fixtures.Memberships.fetch_membership(fixture.owner.actor.id)
      |> Fixtures.Memberships.force_runner_access(Emisar.Accounts.RunnerAccess.none())

      assert {:ok, execution} =
               Runbooks.fetch_execution_recovery_identity(
                 fixture.execution_id,
                 fixture.subject
               )

      assert execution.id == fixture.execution_id
      assert execution.kind == :published
    end

    test "denies a principal without visibility and isolates another account" do
      fixture = mcp_execution_fixture()
      runner_subject = Subject.for_runner(fixture.runner, fixture.account)

      assert Runbooks.fetch_execution_recovery_identity(
               fixture.execution_id,
               runner_subject
             ) == {:error, :unauthorized}

      {_user, _account, other_subject} = Fixtures.Subjects.owner_subject()

      assert Runbooks.fetch_execution_recovery_identity(
               fixture.execution_id,
               other_subject
             ) == {:error, :not_found}
    end
  end

  describe "fetch_execution_result/2" do
    test "returns durable stages, items, and only the latest physical attempt" do
      fixture = mcp_execution_fixture()

      assert {:ok, result} =
               Runbooks.fetch_execution_result(fixture.execution_id, fixture.subject)

      assert result.execution.id == fixture.execution_id
      assert result.runbook.id == fixture.runbook.id
      assert [%{position: 0}] = result.execution.stages
      assert [%{step_id: "uptime"}] = result.execution.items
      assert [%{runbook_execution_id: execution_id}] = result.latest_attempts
      assert execution_id == fixture.execution_id
    end

    test "denies and isolates the result before projecting attempts" do
      fixture = mcp_execution_fixture()
      runner_subject = Subject.for_runner(fixture.runner, fixture.account)

      assert Runbooks.fetch_execution_result(fixture.execution_id, runner_subject) ==
               {:error, :unauthorized}

      {_user, _account, other_subject} = Fixtures.Subjects.owner_subject()

      assert Runbooks.fetch_execution_result(fixture.execution_id, other_subject) ==
               {:error, :not_found}
    end
  end

  describe "execution_projection/1" do
    test "projects a dispatched execution's durable rows and latest attempt" do
      fixture = mcp_execution_fixture()

      assert {:ok, result} =
               Runbooks.fetch_execution_result(fixture.execution_id, fixture.subject)

      projection = Runbooks.execution_projection(result)

      assert projection.execution.status == :active
      assert projection.execution.waitable?
      refute projection.execution.terminal?

      assert [%{stage_id: "inspect", position: 0, status: :active, items: [item]}] =
               projection.stages

      assert item.step_id == "uptime"
      assert item.status == :running
      assert [attempt] = result.latest_attempts
      assert item.latest_attempt.id == attempt.id
    end

    test "states waitable and terminal for every execution status" do
      for {status, waitable?, terminal?} <- [
            {:pending_approval, true, false},
            {:active, true, false},
            {:succeeded, false, true},
            {:halted, false, true},
            {:cancelled, false, true},
            {:unrecognized, false, false}
          ] do
        projection = Runbooks.execution_projection(projected_result(status: status))

        assert projection.execution.status == status
        assert projection.execution.waitable? == waitable?
        assert projection.execution.terminal? == terminal?
      end
    end

    test "resolves every item status branch, halt before cancellation" do
      for {item_status, attempt_count, stage_status, execution_status, expected} <- [
            {:pending, 0, :halted, :active, :halted},
            {:pending, 0, :active, :halted, :halted},
            {:pending, 0, :cancelled, :halted, :halted},
            {:pending, 0, :cancelled, :active, :cancelled},
            {:pending, 0, :active, :cancelled, :cancelled},
            {:pending, 0, :active, :active, :queued},
            {:failed, 0, :active, :active, :not_run},
            {:failed, 2, :halted, :halted, :failed},
            {:running, 1, :active, :active, :running},
            {:waiting, 2, :active, :active, :waiting},
            {:succeeded, 1, :succeeded, :succeeded, :succeeded},
            {:cancelled, 1, :cancelled, :cancelled, :cancelled}
          ] do
        stage = projected_stage(status: stage_status)
        item = projected_item(stage, status: item_status, attempt_count: attempt_count)

        result =
          projected_result(status: execution_status, stages: [%{stage | items: [item]}])

        projection = Runbooks.execution_projection(result)

        assert [%{items: [projected]}] = projection.stages
        assert projected.status == expected
      end
    end

    test "blocks on the terminal item cause a halted execution recorded" do
      stage = projected_stage(status: :halted)

      items = [
        projected_item(stage, status: :succeeded, step_position: 0, attempt_count: 1),
        projected_item(stage,
          status: :failed,
          step_position: 1,
          step_id: "apply",
          runner_ref: "db-two~" <> String.duplicate("2", 32),
          attempt_count: 1,
          terminal_code: "action_failed",
          terminal_message: "The action attempt did not succeed."
        )
      ]

      result =
        projected_result(
          status: :halted,
          terminal_code: "step_failed",
          terminal_message: "Execution stopped.",
          stages: [%{stage | items: items}]
        )

      assert Runbooks.execution_projection(result).execution.blocking == %{
               code: "action_failed",
               message: "The action attempt did not succeed.",
               stage_id: "inspect",
               step_id: "apply",
               runner_ref: "db-two~" <> String.duplicate("2", 32)
             }
    end

    test "falls back to the execution cause when no item recorded one" do
      stage = projected_stage(status: :halted)
      item = projected_item(stage, status: :pending)

      result =
        projected_result(
          status: :halted,
          terminal_code: "approval_denied",
          stages: [%{stage | items: [item]}]
        )

      assert Runbooks.execution_projection(result).execution.blocking == %{
               code: "approval_denied",
               message: "Execution halted.",
               stage_id: "inspect",
               step_id: nil,
               runner_ref: nil
             }
    end

    test "blocks on approval, then on the first waiting item, then not at all" do
      stage = projected_stage(status: :active)
      waiting = projected_item(stage, status: :waiting, attempt_count: 1)
      queued = projected_item(stage, status: :pending, step_position: 1, step_id: "apply")
      stage = %{stage | items: [waiting, queued]}

      held = Runbooks.execution_projection(projected_result(status: :pending_approval))

      assert held.execution.blocking == %{
               code: "approval_required",
               message: "Runbook execution approval is required.",
               stage_id: nil,
               step_id: nil,
               runner_ref: nil
             }

      waiting_projection =
        Runbooks.execution_projection(projected_result(status: :active, stages: [stage]))

      assert waiting_projection.execution.blocking == %{
               code: "waiting",
               message: "A success condition is waiting for another observation.",
               stage_id: "inspect",
               step_id: "uptime",
               runner_ref: waiting.runner_ref
             }

      running = %{stage | items: [%{waiting | status: :running}, queued]}

      running_projection =
        Runbooks.execution_projection(projected_result(status: :active, stages: [running]))

      assert running_projection.execution.blocking == nil
    end

    test "orders stages by position and items by stage, step, and runner" do
      first = projected_stage(stage_id: "inspect", position: 0)
      second = projected_stage(stage_id: "apply", position: 1)

      first_items = [
        projected_item(first, step_position: 1, step_id: "uptime", runner_ref: runner_ref("b")),
        projected_item(first, step_position: 0, step_id: "disk", runner_ref: runner_ref("d")),
        projected_item(first, step_position: 1, step_id: "uptime", runner_ref: runner_ref("a"))
      ]

      second_items = [projected_item(second, step_position: 0, step_id: "restart")]

      result =
        projected_result(stages: [%{second | items: second_items}, %{first | items: first_items}])

      projection = Runbooks.execution_projection(result)

      assert Enum.map(projection.stages, & &1.stage_id) == ["inspect", "apply"]

      assert [inspect_stage, apply_stage] = projection.stages

      assert Enum.map(inspect_stage.items, &{&1.step_id, &1.runner_ref}) == [
               {"disk", runner_ref("d")},
               {"uptime", runner_ref("a")},
               {"uptime", runner_ref("b")}
             ]

      assert Enum.map(apply_stage.items, & &1.step_id) == ["restart"]
    end

    test "shows a value only where exactly one declaration proves it public" do
      secret = "billing-api-token"

      output_plan = [
        %{"id" => "ready", "source" => "structured_output", "sensitive" => false},
        %{"id" => "token", "source" => "stdout", "sensitive" => true},
        %{"id" => "host", "source" => "stdout", "sensitive" => "false"},
        %{"id" => "port", "source" => "stdout"},
        %{"id" => "region", "source" => "stdout", "sensitive" => nil},
        %{"id" => "shard", "source" => "stdout", "sensitive" => false},
        %{"id" => "shard", "source" => "stdout", "sensitive" => true}
      ]

      success_plan = [
        %{"output" => "ready", "operator" => "equals", "value" => true},
        %{"output" => "token", "operator" => "equals", "value" => secret},
        %{"output" => "absent", "operator" => "equals", "value" => secret}
      ]

      outputs = %{
        "ready" => true,
        "token" => secret,
        "host" => secret,
        "port" => secret,
        "region" => secret,
        "shard" => secret
      }

      stage = projected_stage(status: :active)

      item =
        projected_item(stage,
          status: :succeeded,
          attempt_count: 1,
          output_plan: output_plan,
          success_plan: success_plan,
          outputs: outputs,
          success_evidence: [
            %{"kind" => "extraction", "output" => "ready", "status" => "extracted"},
            %{"kind" => "condition", "output" => "ready", "status" => "passed"}
          ]
        )

      result = projected_result(stages: [%{stage | items: [item]}])
      assert [%{items: [projected]}] = Runbooks.execution_projection(result).stages

      assert Enum.map(projected.outputs, &{&1.output_id, &1.sensitive, &1.status, &1.value}) == [
               {"ready", false, "extracted", true},
               {"token", true, "pending", "[REDACTED]"},
               {"host", true, "pending", "[REDACTED]"},
               {"port", true, "pending", "[REDACTED]"},
               {"region", true, "pending", "[REDACTED]"},
               {"shard", true, "pending", "[REDACTED]"},
               {"shard", true, "pending", "[REDACTED]"}
             ]

      assert Enum.map(projected.conditions, &{&1.output, &1.sensitive, &1.expected, &1.status}) ==
               [
                 {"ready", false, true, "passed"},
                 {"token", true, "[REDACTED]", "pending"},
                 {"absent", true, "[REDACTED]", "pending"}
               ]

      assert projected.output_count == 7
      assert projected.condition_count == 3
      refute inspect(projected.outputs) =~ secret
      refute inspect(projected.conditions) =~ secret
      refute inspect(projected.evidence) =~ secret
    end

    test "carries evidence status only, naming an unmet condition during a wait" do
      evidence = [
        %{
          "kind" => "condition",
          "output" => "ready",
          "operator" => "equals",
          "actual" => "still-booting",
          "expected" => true,
          "status" => "failed"
        },
        %{"kind" => "extraction", "output" => "ready", "value" => "still-booting"}
      ]

      stage = projected_stage(status: :active)

      waiting =
        projected_item(stage, status: :waiting, attempt_count: 1, success_evidence: evidence)

      result = projected_result(stages: [%{stage | items: [waiting]}])
      assert [%{items: [projected]}] = Runbooks.execution_projection(result).stages

      assert projected.evidence == [
               %{kind: "condition", output: "ready", operator: "equals", status: "not met"},
               %{kind: "extraction", output: "ready", operator: nil, status: "pending"}
             ]

      failed = %{waiting | status: :failed}
      failed_result = projected_result(stages: [%{stage | items: [failed]}])
      assert [%{items: [settled]}] = Runbooks.execution_projection(failed_result).stages
      assert Enum.map(settled.evidence, & &1.status) == ["failed", "pending"]
    end
  end

  describe "list_recent_executions_for_runbook/3" do
    test "returns bounded current-scope history and hides it after runner-scope loss" do
      fixture = mcp_execution_fixture()

      assert {:ok, [execution]} =
               Runbooks.list_recent_executions_for_runbook(
                 fixture.runbook,
                 fixture.subject,
                 1
               )

      assert execution.id == fixture.execution_id

      fixture.account.id
      |> Fixtures.Memberships.fetch_membership(fixture.owner.actor.id)
      |> Fixtures.Memberships.force_runner_access(Emisar.Accounts.RunnerAccess.none())

      assert {:ok, []} =
               Runbooks.list_recent_executions_for_runbook(
                 fixture.runbook,
                 fixture.subject,
                 1
               )
    end
  end

  describe "list_recent_executions/2" do
    test "returns bounded account history with its runbook and excludes other accounts" do
      fixture = mcp_execution_fixture()

      assert {:ok, [execution]} =
               Runbooks.list_recent_executions(fixture.owner, 1)

      assert execution.id == fixture.execution_id
      assert execution.runbook.id == fixture.runbook.id
      assert execution.runbook.title == fixture.runbook.title

      {_user, _account, other_subject} = Fixtures.Subjects.owner_subject()
      assert {:ok, []} = Runbooks.list_recent_executions(other_subject, 5)
    end

    test "denies a principal without runbook visibility" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      assert Runbooks.list_recent_executions(Subject.for_runner(runner, account), 5) ==
               {:error, :unauthorized}
    end
  end

  describe "execution_who_via/1" do
    test "names the requesting operator account-locally with no channel" do
      {user, account, owner} = Fixtures.Subjects.owner_subject()
      _policy = Fixtures.Policies.create_policy(account_id: account.id)
      runner = trusted_runner(account, owner)
      Runners.subscribe_runner_transport(runner)

      runbook =
        create_runbook(owner, definition: definition(runner.group))
        |> Fixtures.Runbooks.publish_runbook()

      assert {:ok, %{execution_id: execution_id}} =
               Runbooks.dispatch_runbook(runbook, "inspect fleet", owner)

      assert {:ok, result} = Runbooks.fetch_execution_result(execution_id, owner)
      assert Runbooks.execution_who_via(result.execution) == {"Test User", nil}

      account.id
      |> Fixtures.Memberships.fetch_membership(user.id)
      |> Fixtures.Memberships.sync_display_name("Directory Ops")

      assert {:ok, renamed} = Runbooks.fetch_execution_result(execution_id, owner)
      assert Runbooks.execution_who_via(renamed.execution) == {"Directory Ops", nil}
    end

    test "an MCP execution names the key owner with the key as the channel" do
      fixture = mcp_execution_fixture()

      assert {:ok, result} =
               Runbooks.fetch_execution_result(fixture.execution_id, fixture.owner)

      assert Runbooks.execution_who_via(result.execution) == {"Test User", "execution client"}
    end

    test "a gone membership degrades the key owner to their email" do
      fixture = mcp_execution_fixture()
      owner_user = fixture.owner.actor
      admin = membership_subject(fixture.account, "admin")

      fixture.account.id
      |> Fixtures.Memberships.fetch_membership(owner_user.id)
      |> Fixtures.Memberships.mark_membership_as_deleted()

      assert {:ok, result} = Runbooks.fetch_execution_result(fixture.execution_id, admin)

      assert Runbooks.execution_who_via(result.execution) ==
               {owner_user.email, "execution client"}
    end

    test "missing actor rows degrade honestly" do
      {user, account, owner} = Fixtures.Subjects.owner_subject()
      _policy = Fixtures.Policies.create_policy(account_id: account.id)
      runner = trusted_runner(account, owner)
      Runners.subscribe_runner_transport(runner)

      runbook =
        create_runbook(owner, definition: definition(runner.group))
        |> Fixtures.Runbooks.publish_runbook()

      assert {:ok, %{execution_id: execution_id}} =
               Runbooks.dispatch_runbook(runbook, "inspect fleet", owner)

      Fixtures.Users.mark_user_as_deleted(user)

      assert {:ok, result} = Runbooks.fetch_execution_result(execution_id, owner)
      assert Runbooks.execution_who_via(result.execution) == {nil, nil}

      # A key-dispatched execution whose key row is gone still names its channel.
      assert Runbooks.execution_who_via(%RunbookExecution{
               api_key_id: Repo.generate_id(),
               api_key: nil
             }) == {nil, "LLM agent"}
    end

    test "unloaded attribution stays unknown instead of impersonating a former member" do
      user = Fixtures.Users.create_user(full_name: "Global Name")

      execution = %RunbookExecution{
        requested_by: nil,
        api_key_id: Repo.generate_id(),
        api_key: %Emisar.ApiKeys.ApiKey{name: "Claude Code", created_by: user}
      }

      assert Runbooks.execution_who_via(execution) == {nil, "Claude Code"}
    end

    test "a foreign membership never supplies its directory name" do
      account = Fixtures.Accounts.create_account()
      other_account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user(full_name: "Global Name")

      membership =
        Fixtures.Memberships.create_membership(
          account_id: other_account.id,
          user_id: user.id,
          role: "operator"
        )

      membership = Fixtures.Memberships.sync_display_name(membership, "Foreign Directory Name")

      execution = %RunbookExecution{
        account_id: account.id,
        initiating_membership_id: membership.id,
        initiating_membership: membership,
        requested_by: user
      }

      assert Runbooks.execution_who_via(execution) == {user.email, nil}
    end
  end

  describe "fetch_runbook_for_execution/2" do
    test "retains the immutable source after its visible family is deleted" do
      fixture = mcp_execution_fixture()
      _deleted = delete(fixture.runbook, fixture.owner)
      execution = fetch_execution(fixture.execution_id)

      assert {:ok, fetched} = Runbooks.fetch_runbook_for_execution(execution, fixture.owner)
      assert fetched.id == fixture.runbook.id

      {_user, _account, other_subject} = Fixtures.Subjects.owner_subject()

      assert Runbooks.fetch_runbook_for_execution(execution, other_subject) ==
               {:error, :not_found}
    end
  end

  describe "change_runbook/1" do
    test "builds the metadata form and reports field errors inline" do
      valid = Runbooks.change_runbook(%{"title" => "Deploy check", "slug" => ""})
      assert valid.valid?
      assert valid.changes == %{title: "Deploy check"}

      invalid = Runbooks.change_runbook(%{"title" => "", "slug" => "Bad slug"})
      refute invalid.valid?
      assert "can't be blank" in errors_on(invalid).title
      assert "has invalid format" in errors_on(invalid).slug
    end
  end

  describe "create_runbook/2" do
    test "creates a never-published runbook holding its first draft, derives its slug, audits it" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      Runbooks.subscribe_account_runbooks(account.id)
      attrs = runbook_attrs(title: "Database Health", slug: "")

      assert {:ok, runbook} = Runbooks.create_runbook(attrs, subject)
      assert runbook.live_version == nil
      assert runbook.definition == nil
      assert runbook.slug == "database-health"
      assert runbook.draft_definition == definition()
      assert_receive {:list_changed, :runbook, "runbook.created", runbook_id}
      assert runbook_id == runbook.id

      created_event =
        Emisar.Audit.Event
        |> Repo.all()
        |> Enum.find(&(&1.event_type == "runbook.created" and &1.target_id == runbook.id))

      assert created_event.target_id == runbook.id
    end

    test "persists an incomplete draft but keeps publication on the strict contract" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()

      incomplete =
        definition()
        |> put_in(["stages", Access.at(0), "steps", Access.at(0), "action"], "")

      attrs = runbook_attrs(title: "Work in progress", definition: incomplete)
      assert {:ok, runbook} = Runbooks.create_runbook(attrs, subject)
      assert runbook.draft_definition == incomplete

      assert {:error, [%{path: "/stages/0/steps/0/action"} | _rest]} =
               Runbooks.publish_draft(runbook, subject)

      assert Repo.reload!(runbook).live_version == nil
    end

    test "refuses a second runbook on a slug the account already uses" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      assert {:ok, _first} = Runbooks.create_runbook(runbook_attrs(slug: "taken"), subject)

      assert {:error, changeset} = Runbooks.create_runbook(runbook_attrs(slug: "taken"), subject)
      assert "has already been taken" in errors_on(changeset).account_id
    end

    test "denies a principal without draft permission" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      assert Runbooks.create_runbook(
               runbook_attrs(),
               Subject.for_runner(runner, account)
             ) == {:error, :unauthorized}
    end
  end

  describe "import_runbook/3" do
    test "strictly imports canonical JSON as an account-scoped first draft" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      definition = definition()

      assert {:ok, runbook} =
               Runbooks.import_runbook("Imported maintenance", Jason.encode!(definition), subject)

      assert runbook.account_id == account.id
      assert runbook.title == "Imported maintenance"
      assert runbook.slug == "imported-maintenance"
      assert runbook.live_version == nil
      assert runbook.draft_definition == definition

      {_other_user, _other_account, other_subject} = Fixtures.Subjects.owner_subject()
      assert Runbooks.fetch_runbook_by_id(runbook.id, other_subject) == {:error, :not_found}
    end

    test "rejects invalid definitions before persistence" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()

      assert {:error, [%{path: "/stages"}]} =
               Runbooks.import_runbook(
                 "Incomplete import",
                 Jason.encode!(%{
                   "schema_version" => 1,
                   "context_markdown" => "",
                   "inputs" => []
                 }),
                 subject
               )
    end

    test "denies a principal without draft permission" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      assert Runbooks.import_runbook(
               "Denied import",
               Jason.encode!(definition()),
               Subject.for_runner(runner, account)
             ) == {:error, :unauthorized}
    end
  end

  describe "create_or_replay_mcp_draft/2" do
    test "creates and replays exactly once, then rejects changed facts" do
      {_user, account, owner} = Fixtures.Subjects.owner_subject()
      subject = api_client_subject(account, owner, "draft replay")
      facts = mcp_draft_facts(title: "Agent draft")
      Runbooks.subscribe_account_runbooks(account.id)

      assert {:ok, :created, created} = Runbooks.create_or_replay_mcp_draft(facts, subject)

      assert_receive {:list_changed, :runbook, "runbook.created", created_id}
      assert created_id == created.id

      assert {:ok, :replay, replayed} = Runbooks.create_or_replay_mcp_draft(facts, subject)
      assert replayed.id == created.id
      refute_receive {:list_changed, :runbook, _, _}, 50

      changed = %{facts | title: "Renamed draft"}

      assert Runbooks.create_or_replay_mcp_draft(changed, subject) ==
               {:error, :operation_conflict}

      assert Repo.aggregate(Runbooks.Runbook, :count) == 1
      assert Repo.aggregate(MCPOperations.Operation, :count) == 1
    end

    test "reports an incomplete operation when the committed draft is missing" do
      {_user, account, owner} = Fixtures.Subjects.owner_subject()
      subject = api_client_subject(account, owner, "incomplete draft")
      facts = mcp_draft_facts()

      assert {:ok, :created, created} = Runbooks.create_or_replay_mcp_draft(facts, subject)
      Repo.delete!(created)

      assert Runbooks.create_or_replay_mcp_draft(facts, subject) ==
               {:error, :operation_incomplete}
    end

    test "concurrent identical first attempts create exactly one draft" do
      {_user, account, owner} = Fixtures.Subjects.owner_subject()
      subject = api_client_subject(account, owner, "concurrent draft")
      facts = mcp_draft_facts()

      results =
        1..8
        |> Enum.map(fn _index ->
          Task.async(fn -> Runbooks.create_or_replay_mcp_draft(facts, subject) end)
        end)
        |> Enum.map(&Task.await(&1, 5_000))

      assert Enum.count(results, &match?({:ok, :created, _runbook}, &1)) == 1

      draft_ids =
        results |> Enum.map(fn {:ok, _outcome, runbook} -> runbook.id end) |> Enum.uniq()

      assert length(draft_ids) == 1
      assert Repo.aggregate(Runbooks.Runbook, :count) == 1
      assert Repo.aggregate(MCPOperations.Operation, :count) == 1
    end

    test "rolls the reservation back with an invalid definition" do
      {_user, account, owner} = Fixtures.Subjects.owner_subject()
      subject = api_client_subject(account, owner, "invalid draft")
      facts = mcp_draft_facts(definition: %{"schema_version" => 1})

      assert {:error, [%{path: "/context_markdown"} | _rest]} =
               Runbooks.create_or_replay_mcp_draft(facts, subject)

      refute Repo.exists?(Runbooks.Runbook)
      refute Repo.exists?(MCPOperations.Operation)
    end

    test "denies before reporting definition issues" do
      {_user, account, _owner} = Fixtures.Subjects.owner_subject()
      subject = membership_subject(account, :operator)
      facts = mcp_draft_facts(definition: %{"schema_version" => 1})

      assert Runbooks.create_or_replay_mcp_draft(facts, subject) == {:error, :unauthorized}

      refute Repo.exists?(Runbooks.Runbook)
      refute Repo.exists?(MCPOperations.Operation)
    end

    test "isolates the same operation id across lineages and accounts" do
      {_user, account, owner} = Fixtures.Subjects.owner_subject()
      subject = api_client_subject(account, owner, "own draft")
      facts = mcp_draft_facts()

      assert {:ok, :created, created} = Runbooks.create_or_replay_mcp_draft(facts, subject)

      # Same operation id, second lineage: its own reservation and its own
      # draft. The slug differs only because slugs are unique per account.
      peer_subject = api_client_subject(account, owner, "peer draft")
      peer_facts = %{facts | slug: "peer-draft"}

      assert {:ok, :created, peer} = Runbooks.create_or_replay_mcp_draft(peer_facts, peer_subject)
      refute peer.id == created.id

      {_other_user, other_account, other_owner} = Fixtures.Subjects.owner_subject()
      other_subject = api_client_subject(other_account, other_owner, "foreign draft")

      assert {:ok, :created, foreign} = Runbooks.create_or_replay_mcp_draft(facts, other_subject)
      refute foreign.id == created.id
      assert foreign.account_id == other_account.id
    end
  end

  describe "create_or_replay_mcp_draft_update/2" do
    test "updates the runbook's one draft once and rejects a stale base digest" do
      {_user, account, owner} = Fixtures.Subjects.owner_subject()
      subject = api_client_subject(account, owner, "draft update")
      source = create_runbook(owner, slug: "health-review")
      revision = put_in(definition(), ["context_markdown"], "Inspect twice.")

      facts =
        mcp_draft_update_facts(source, title: "Health review revised", definition: revision)

      assert {:ok, :created, revised} = Runbooks.create_or_replay_mcp_draft_update(facts, subject)

      assert revised.id == source.id
      assert revised.slug == source.slug
      assert revised.title == "Health review revised"
      assert revised.draft_definition == revision
      assert revised.live_version == nil

      assert {:ok, :replay, replayed} = Runbooks.create_or_replay_mcp_draft_update(facts, subject)
      assert replayed.id == revised.id

      stale = %{facts | operation_id: "op_244NN9NMDZ1T76NARWCKM5A0D6"}

      assert Runbooks.create_or_replay_mcp_draft_update(stale, subject) ==
               {:error, :draft_changed}

      assert Repo.aggregate(Runbooks.Runbook, :count) == 1
      assert Repo.aggregate(MCPOperations.Operation, :count) == 1
    end

    test "writes a draft over a live release while that release keeps running" do
      {_user, account, owner} = Fixtures.Subjects.owner_subject()
      subject = api_client_subject(account, owner, "draft update")
      runner = trusted_runner(account, owner)

      live =
        owner
        |> create_runbook(slug: "health-review", definition: definition(runner.group))
        |> Fixtures.Runbooks.publish_runbook()

      facts = mcp_draft_update_facts(live, title: "Health review revised")

      assert {:ok, :created, revised} = Runbooks.create_or_replay_mcp_draft_update(facts, subject)

      assert revised.id == live.id
      assert revised.live_version == 1
      assert revised.definition == live.definition
      assert revised.draft_definition == facts.definition

      assert {:ok, still_live} = Runbooks.fetch_model_visible_runbook("health-review", subject)
      assert still_live.definition == live.definition
    end

    test "rolls back stale digests and hides cross-account runbooks" do
      {_user, account, owner} = Fixtures.Subjects.owner_subject()
      subject = api_client_subject(account, owner, "draft update")
      source = create_runbook(owner, slug: "health-review")

      stale_digest =
        source
        |> mcp_draft_update_facts()
        |> Map.put(:definition_sha256, String.duplicate("0", 64))

      assert Runbooks.create_or_replay_mcp_draft_update(stale_digest, subject) ==
               {:error, :draft_changed}

      {_other_user, other_account, other_owner} = Fixtures.Subjects.owner_subject()
      other_subject = api_client_subject(other_account, other_owner, "foreign update")

      assert Runbooks.create_or_replay_mcp_draft_update(
               mcp_draft_update_facts(source),
               other_subject
             ) == {:error, :not_found}

      refute Repo.exists?(MCPOperations.Operation)
    end

    test "conflicts when changed facts reuse the operation identity" do
      {_user, account, owner} = Fixtures.Subjects.owner_subject()
      subject = api_client_subject(account, owner, "draft update")
      source = create_runbook(owner, slug: "health-review")
      facts = mcp_draft_update_facts(source)

      assert {:ok, :created, _revised} =
               Runbooks.create_or_replay_mcp_draft_update(facts, subject)

      assert Runbooks.create_or_replay_mcp_draft_update(%{facts | title: "Renamed"}, subject) ==
               {:error, :operation_conflict}

      assert Repo.aggregate(Runbooks.Runbook, :count) == 1
      assert Repo.aggregate(MCPOperations.Operation, :count) == 1
    end

    test "denies a caller holding neither draft nor manage authority" do
      {_user, account, owner} = Fixtures.Subjects.owner_subject()
      subject = api_client_subject(account, owner, "draft update")
      source = create_runbook(owner, slug: "health-review")
      facts = mcp_draft_update_facts(source)

      narrowed =
        subject
        |> without_permission(Runbooks.Authorizer.draft_runbooks_permission())
        |> without_permission(Runbooks.Authorizer.manage_runbooks_permission())

      assert Runbooks.create_or_replay_mcp_draft_update(facts, narrowed) ==
               {:error, :unauthorized}

      assert Runbooks.create_or_replay_mcp_draft_update(
               facts,
               membership_subject(account, :operator)
             ) == {:error, :unauthorized}

      refute Repo.exists?(MCPOperations.Operation)
    end

    test "accepts a canonical draft that is not yet publishable" do
      {_user, account, owner} = Fixtures.Subjects.owner_subject()
      subject = api_client_subject(account, owner, "draft update")
      source = create_runbook(owner, slug: "health-review")

      incomplete =
        update_in(
          definition(),
          ["stages", Access.at(0), "steps", Access.at(0)],
          &Map.delete(&1, "action")
        )

      facts = mcp_draft_update_facts(source, definition: incomplete)

      assert {:ok, :created, revised} = Runbooks.create_or_replay_mcp_draft_update(facts, subject)
      assert revised.draft_definition == incomplete

      # The draft passes the envelope precisely because publication validation
      # is a separate, human-only transition.
      assert {:ok, _draft} = Runbooks.Definition.validate_draft(revised.draft_definition)
      assert {:error, _issues} = Runbooks.Definition.validate(revised.draft_definition)
    end
  end

  describe "save_draft/4" do
    # The authorizer states in writing that :api_client gets draft but NOT
    # manage, so the console's save stays closed to it at the DOMAIN layer, not
    # merely by which tools the MCP wiring happens to expose today.
    test "denies an MCP key, which holds draft but not manage" do
      {_user, account, owner} = Fixtures.Subjects.owner_subject()
      runbook = create_runbook(owner, slug: "manage-gate")

      assert Runbooks.save_draft(
               runbook,
               %{"description" => "escalated"},
               base_sha(runbook),
               api_client_subject(account, owner, "save-draft gate")
             ) == {:error, :unauthorized}
    end

    test "writes the draft in place, audits it, and isolates cross-account callers" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runbook = create_runbook(subject, slug: "immutable")
      Runbooks.subscribe_account_runbooks(account.id)

      attrs = %{"title" => "Second", "slug" => "second", "description" => "updated"}
      assert {:ok, saved} = Runbooks.save_draft(runbook, attrs, base_sha(runbook), subject)

      assert saved.id == runbook.id
      assert saved.slug == "second"
      assert saved.title == "Second"
      assert saved.draft_definition == definition()
      assert_receive {:list_changed, :runbook, "runbook.updated", runbook_id}
      assert runbook_id == runbook.id

      updated_event =
        Emisar.Audit.Event
        |> Repo.all()
        |> Enum.find(&(&1.event_type == "runbook.updated"))

      assert updated_event.target_id == runbook.id

      {_user, _account, other_subject} = Fixtures.Subjects.owner_subject()

      assert Runbooks.save_draft(runbook, attrs, base_sha(saved), other_subject) ==
               {:error, :not_found}
    end

    test "refuses a save written on top of someone else's" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      runbook = create_runbook(subject, slug: "sha-locked")
      stale_sha = base_sha(runbook)

      revised = put_in(definition(), ["context_markdown"], "Inspect twice.")
      attrs = %{"draft_definition" => revised}
      assert {:ok, _saved} = Runbooks.save_draft(runbook, attrs, stale_sha, subject)

      assert Runbooks.save_draft(runbook, %{"description" => "forked"}, stale_sha, subject) ==
               {:error, :draft_changed}

      assert Repo.one(Runbooks.Runbook).draft_definition == revised
    end

    test "locks the base digest to the live release once the draft is gone" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      live = subject |> create_runbook(slug: "published") |> Fixtures.Runbooks.publish_runbook()

      assert live.draft_definition == nil
      revised = put_in(definition(), ["context_markdown"], "Inspect twice.")
      attrs = %{"draft_definition" => revised}

      assert Runbooks.save_draft(live, attrs, String.duplicate("0", 64), subject) ==
               {:error, :draft_changed}

      assert {:ok, saved} = Runbooks.save_draft(live, attrs, base_sha(live), subject)
      assert saved.draft_definition == revised
      assert saved.definition == live.definition
    end

    test "a metadata-only save lands in place and creates no unpublished change" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      live = subject |> create_runbook(slug: "published") |> Fixtures.Runbooks.publish_runbook()

      assert {:ok, saved} =
               Runbooks.save_draft(live, %{"description" => "clearer"}, base_sha(live), subject)

      assert saved.description == "clearer"
      assert saved.draft_definition == nil
      assert saved.live_version == 1
    end

    test "freezes the slug once a release exists" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      live = subject |> create_runbook(slug: "frozen") |> Fixtures.Runbooks.publish_runbook()

      assert {:error, changeset} =
               Runbooks.save_draft(live, %{"slug" => "renamed"}, base_sha(live), subject)

      assert "cannot change once the runbook has been published" in errors_on(changeset).slug
      assert Repo.reload!(live).slug == "frozen"
    end

    test "denies a principal without manage permission" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runbook = create_runbook(subject)
      operator = membership_subject(account, "operator")

      assert Runbooks.save_draft(runbook, %{}, base_sha(runbook), operator) ==
               {:error, :unauthorized}
    end
  end

  describe "publish_draft/2" do
    test "mints the next release, promotes the draft, and clears it" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      _policy = Fixtures.Policies.create_policy(account_id: account.id)
      runner = trusted_runner(account, subject)
      runbook = create_runbook(subject, definition: definition(runner.group))
      Runbooks.subscribe_account_runbooks(account.id)

      assert {:ok, published} = Runbooks.publish_draft(runbook, subject)

      assert published.live_version == 1
      assert published.definition == definition(runner.group)
      assert published.draft_definition == nil
      assert_receive {:list_changed, :runbook, "runbook.published", runbook_id}
      assert runbook_id == published.id

      assert release = Repo.one(Runbooks.Release)
      assert release.runbook_id == published.id
      assert release.version == 1
      assert release.definition == published.definition
      assert release.definition_sha256 == Runbooks.definition_digest(published.definition)

      published_event =
        Emisar.Audit.Event
        |> Repo.all()
        |> Enum.find(&(&1.event_type == "runbook.published"))

      assert published_event.target_id == published.id
      assert published_event.payload["version"] == 1
      assert published_event.payload["definition_sha256"] == release.definition_sha256
    end

    test "counts publishes, not saves" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      _policy = Fixtures.Policies.create_policy(account_id: account.id)
      runner = trusted_runner(account, subject)
      runbook = create_runbook(subject, definition: definition(runner.group))

      assert {:ok, first} = Runbooks.publish_draft(runbook, subject)

      revised = put_in(definition(runner.group), ["context_markdown"], "Inspect twice.")
      attrs = %{"draft_definition" => revised}
      assert {:ok, saved} = Runbooks.save_draft(first, attrs, base_sha(first), subject)
      assert {:ok, second} = Runbooks.publish_draft(saved, subject)

      assert second.live_version == 2
      assert second.definition == revised
      assert Enum.map(Repo.all(Runbooks.Release), & &1.version) == [1, 2]
    end

    test "refuses a runbook with nothing unpublished" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      _policy = Fixtures.Policies.create_policy(account_id: account.id)
      runner = trusted_runner(account, subject)

      live =
        subject
        |> create_runbook(definition: definition(runner.group))
        |> Fixtures.Runbooks.publish_runbook()

      assert Runbooks.publish_draft(live, subject) == {:error, :no_draft}
    end

    test "rechecks readiness from fresh domain state, not the caller's snapshot" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      _policy = Fixtures.Policies.create_policy(account_id: account.id)
      runner = trusted_runner(account, subject)
      runbook = create_runbook(subject, definition: definition(runner.group))

      # The catalog the caller saw is gone by the time publish runs.
      Fixtures.Catalog.delete_actions_for_runner(runner.id)

      assert {:error, issues} = Runbooks.publish_draft(runbook, subject)
      assert is_list(issues)

      reloaded = Repo.reload!(runbook)
      assert reloaded.live_version == nil
      assert reloaded.draft_definition == runbook.draft_definition
      refute Repo.exists?(Runbooks.Release)
    end

    test "denies a principal without manage permission" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runbook = create_runbook(subject)
      operator = membership_subject(account, "operator")

      assert Runbooks.publish_draft(runbook, operator) == {:error, :unauthorized}
    end

    test "denies cross-account mutation" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      _policy = Fixtures.Policies.create_policy(account_id: account.id)
      runner = trusted_runner(account, subject)
      runbook = create_runbook(subject, definition: definition(runner.group))

      {_user, _account, other_subject} = Fixtures.Subjects.owner_subject()
      assert Runbooks.publish_draft(runbook, other_subject) == {:error, :not_found}
    end
  end

  describe "discard_draft/2" do
    test "drops the unpublished change and leaves the live release running" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      live = subject |> create_runbook(slug: "keeper") |> Fixtures.Runbooks.publish_runbook()
      revised = put_in(definition(), ["context_markdown"], "Inspect twice.")

      assert {:ok, edited} =
               Runbooks.save_draft(
                 live,
                 %{"draft_definition" => revised},
                 base_sha(live),
                 subject
               )

      Runbooks.subscribe_account_runbooks(account.id)

      assert {:ok, discarded} = Runbooks.discard_draft(edited, subject)
      assert discarded.draft_definition == nil
      assert discarded.definition == live.definition
      assert discarded.live_version == 1
      assert_receive {:list_changed, :runbook, "runbook.updated", runbook_id}
      assert runbook_id == live.id
    end

    test "refuses a never-published runbook, whose draft is all there is" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      runbook = create_runbook(subject)

      assert Runbooks.discard_draft(runbook, subject) == {:error, :never_published}
      assert Repo.reload!(runbook).draft_definition == runbook.draft_definition
    end

    test "refuses a live runbook with nothing unpublished" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      live = subject |> create_runbook() |> Fixtures.Runbooks.publish_runbook()

      assert Runbooks.discard_draft(live, subject) == {:error, :no_draft}
    end

    test "denies a principal without manage permission" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      live = subject |> create_runbook() |> Fixtures.Runbooks.publish_runbook()
      operator = membership_subject(account, "operator")

      assert Runbooks.discard_draft(live, operator) == {:error, :unauthorized}
    end

    test "denies cross-account mutation" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      live = subject |> create_runbook() |> Fixtures.Runbooks.publish_runbook()
      {_user, _account, other_subject} = Fixtures.Subjects.owner_subject()

      assert Runbooks.discard_draft(live, other_subject) == {:error, :not_found}
    end
  end

  describe "delete_runbook/2" do
    # Same domain-layer invariant as save_draft/4: delete is the manage verb an
    # MCP key must never reach.
    test "denies an MCP key, which holds draft but not manage" do
      {_user, account, owner} = Fixtures.Subjects.owner_subject()
      runbook = create_runbook(owner, slug: "delete-gate")

      assert Runbooks.delete_runbook(
               runbook,
               api_client_subject(account, owner, "delete gate")
             ) == {:error, :unauthorized}
    end

    test "soft-deletes the row and retains its releases" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      live = subject |> create_runbook(slug: "family") |> Fixtures.Runbooks.publish_runbook()
      Runbooks.subscribe_account_runbooks(account.id)

      assert {:ok, deleted} = Runbooks.delete_runbook(live, subject)
      assert deleted.deleted_at
      assert Runbooks.fetch_runbook_by_id(live.id, subject) == {:error, :not_found}
      assert Repo.one(Runbooks.Release).runbook_id == live.id
      assert_receive {:list_changed, :runbook, "runbook.deleted", runbook_id}
      assert runbook_id == live.id
    end

    test "does not delete another account's runbook" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      runbook = create_runbook(subject)
      {_user, _account, other_subject} = Fixtures.Subjects.owner_subject()

      assert Runbooks.delete_runbook(runbook, other_subject) == {:error, :not_found}
      assert {:ok, _fetched} = Runbooks.fetch_runbook_by_id(runbook.id, subject)
    end
  end

  describe "subscribe_account_runbooks/1" do
    test "delivers exact account-local list changes" do
      {_user, account, _subject} = Fixtures.Subjects.owner_subject()
      {_user, _other_account, other_subject} = Fixtures.Subjects.owner_subject()
      assert :ok = Runbooks.subscribe_account_runbooks(account.id)
      assert {:ok, _other} = Runbooks.create_runbook(runbook_attrs(), other_subject)
      refute_receive {:list_changed, :runbook, _, _}
    end
  end

  describe "subscribe_execution/2" do
    test "subscribes only to the exact account and execution topic" do
      account_id = Ecto.UUID.generate()
      execution_id = Ecto.UUID.generate()
      other_execution_id = Ecto.UUID.generate()

      assert :ok = Runbooks.subscribe_execution(account_id, execution_id)
      assert :ok = Runbooks.broadcast_execution_updated(account_id, other_execution_id)
      refute_receive {:runbook_execution_updated, ^other_execution_id}
      assert :ok = Runbooks.broadcast_execution_updated(account_id, execution_id)
      assert_receive {:runbook_execution_updated, ^execution_id}
    end
  end

  describe "unsubscribe_execution/2" do
    test "stops delivery from the exact execution topic" do
      account_id = Ecto.UUID.generate()
      execution_id = Ecto.UUID.generate()

      assert :ok = Runbooks.subscribe_execution(account_id, execution_id)
      assert :ok = Runbooks.unsubscribe_execution(account_id, execution_id)
      assert :ok = Runbooks.broadcast_execution_updated(account_id, execution_id)
      refute_receive {:runbook_execution_updated, ^execution_id}
    end
  end

  describe "broadcast_execution_updated/2" do
    test "emits the bounded reread signal without projecting result data" do
      account_id = Ecto.UUID.generate()
      execution_id = Ecto.UUID.generate()

      assert :ok = Runbooks.subscribe_execution(account_id, execution_id)
      assert :ok = Runbooks.broadcast_execution_updated(account_id, execution_id)
      assert_receive {:runbook_execution_updated, ^execution_id}
    end
  end

  describe "expand/1" do
    test "flattens the live release's steps in declared order and rejects malformed shapes" do
      first = step("first", "one")
      second = step("second", "two")

      runbook = %Runbooks.Runbook{
        definition: definition([stage("one", [first]), stage("two", [second])])
      }

      assert Runbooks.expand(runbook) == [first, second]
      assert Runbooks.expand(%Runbooks.Runbook{definition: %{}}) == []
    end

    test "falls back to the draft while nothing is live" do
      step = step("first", "one")

      runbook = %Runbooks.Runbook{
        definition: nil,
        draft_definition: definition([stage("one", [step])])
      }

      assert Runbooks.expand(runbook) == [step]
      assert Runbooks.expand(%Runbooks.Runbook{definition: nil, draft_definition: nil}) == []
    end
  end

  describe "dispatch_runbook/4" do
    # The only gate is one ensure_has_permissions(dispatch_run_permission()) call,
    # and RunbookRunLive passes current_subject straight through with no
    # Permissions.gated wrapper — unlike cancel_execution right above it. So this
    # single clause is all that stops a :viewer's open socket from a crafted
    # phx-submit fanning a runbook out across the fleet. Nothing exercised it.
    test "denies a viewer, who can read runbooks but not dispatch" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      _policy = Fixtures.Policies.create_policy(account_id: account.id)
      runner = trusted_runner(account, subject)

      runbook =
        subject
        |> create_runbook(definition: definition(runner.group))
        |> Fixtures.Runbooks.publish_runbook()

      assert Runbooks.dispatch_runbook(
               runbook,
               "read-only principal should not dispatch",
               membership_subject(account, :viewer)
             ) == {:error, :unauthorized}

      refute Repo.exists?(RunbookExecution)
    end

    test "creates the durable execution and first physical attempt" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      _policy = Fixtures.Policies.create_policy(account_id: account.id)
      runner = trusted_runner(account, subject)
      Runners.subscribe_runner_transport(runner)

      runbook =
        subject
        |> create_runbook(definition: definition(runner.group))
        |> Fixtures.Runbooks.publish_runbook()

      assert {:ok, result} =
               Runbooks.dispatch_runbook(runbook, "inspect the database", subject)

      assert result.total == 1

      assert [%{runbook_step_id: "uptime"}] =
               Runs.list_runs_for_runbook_execution(account.id, result.execution_id)
    end

    test "rejects a blank reason and a runbook from another account" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      _policy = Fixtures.Policies.create_policy(account_id: account.id)
      runner = trusted_runner(account, subject)

      runbook =
        subject
        |> create_runbook(definition: definition(runner.group))
        |> Fixtures.Runbooks.publish_runbook()

      assert Runbooks.dispatch_runbook(runbook, "  ", subject) == {:error, :reason_required}

      {_user, _account, other_subject} = Fixtures.Subjects.owner_subject()

      assert Runbooks.dispatch_runbook(runbook, "cross account", other_subject) ==
               {:error, :not_found}
    end

    test "refuses a runbook that has never been published" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      _policy = Fixtures.Policies.create_policy(account_id: account.id)
      runner = trusted_runner(account, subject)
      runbook = create_runbook(subject, definition: definition(runner.group))

      assert Runbooks.dispatch_runbook(runbook, "inspect the database", subject) ==
               {:error, :not_live}
    end

    test "snapshots the live definition and its release number onto the execution" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      _policy = Fixtures.Policies.create_policy(account_id: account.id)
      runner = trusted_runner(account, subject)
      Runners.subscribe_runner_transport(runner)

      live =
        subject
        |> create_runbook(definition: definition(runner.group))
        |> Fixtures.Runbooks.publish_runbook()

      revised = put_in(definition(runner.group), ["context_markdown"], "Inspect twice.")
      attrs = %{"draft_definition" => revised}
      assert {:ok, edited} = Runbooks.save_draft(live, attrs, base_sha(live), subject)

      assert {:ok, result} = Runbooks.dispatch_runbook(edited, "inspect the database", subject)

      execution = fetch_execution(result.execution_id)
      assert execution.definition == live.definition
      assert execution.runbook_version == 1
      assert execution.definition_sha256 == Runbooks.definition_digest(live.definition)
    end

    test "refuses a runbook soft-deleted after it was read" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      _policy = Fixtures.Policies.create_policy(account_id: account.id)
      runner = trusted_runner(account, subject)

      runbook =
        subject
        |> create_runbook(definition: definition(runner.group))
        |> Fixtures.Runbooks.publish_runbook()

      Fixtures.Runbooks.mark_runbook_as_deleted(runbook)

      assert Runbooks.dispatch_runbook(runbook, "inspect the database", subject) ==
               {:error, :not_found}

      refute Repo.exists?(RunbookExecution)
    end
  end

  describe "create_or_replay_mcp_execution/2" do
    test "creates the durable execution once and replays it exactly" do
      fixture = mcp_execution_fixture()
      facts = mcp_execution_facts(fixture.runbook, operation_id: fixture.operation_id)

      assert [%{runbook_step_id: "uptime"}] =
               Runs.list_runs_for_runbook_execution(fixture.account.id, fixture.execution_id)

      assert {:ok, :replay, replayed} =
               Runbooks.create_or_replay_mcp_execution(facts, fixture.subject)

      assert replayed.id == fixture.execution_id
      assert Repo.aggregate(RunbookExecution, :count) == 1
      assert Repo.aggregate(MCPOperations.Operation, :count) == 1
    end

    test "replays without resolving the current live runbook" do
      fixture = mcp_execution_fixture()
      facts = mcp_execution_facts(fixture.runbook, operation_id: fixture.operation_id)
      Fixtures.Runbooks.mark_runbook_as_deleted(fixture.runbook)

      assert {:ok, :replay, replayed} =
               Runbooks.create_or_replay_mcp_execution(facts, fixture.subject)

      assert replayed.id == fixture.execution_id
    end

    test "conflicts when a changed immutable fact reuses the identity" do
      fixture = mcp_execution_fixture()

      changed = [
        mcp_execution_facts(fixture.runbook,
          operation_id: fixture.operation_id,
          reason: "different reason"
        ),
        mcp_execution_facts(fixture.runbook,
          operation_id: fixture.operation_id,
          input_values: %{"seconds" => 30}
        ),
        mcp_execution_facts(fixture.runbook,
          operation_id: fixture.operation_id,
          runbook_ref: "#{fixture.runbook.slug}@2"
        )
      ]

      for facts <- changed do
        assert Runbooks.create_or_replay_mcp_execution(facts, fixture.subject) ==
                 {:error, :operation_conflict}
      end

      assert Repo.aggregate(RunbookExecution, :count) == 1
    end

    test "reports an incomplete operation when the committed execution is missing" do
      fixture = mcp_execution_fixture()
      facts = mcp_execution_facts(fixture.runbook, operation_id: fixture.operation_id)
      Repo.delete!(fetch_execution(fixture.execution_id))

      assert Runbooks.create_or_replay_mcp_execution(facts, fixture.subject) ==
               {:error, :operation_incomplete}
    end

    test "concurrent identical first attempts create exactly one execution" do
      {_user, account, owner} = Fixtures.Subjects.owner_subject()
      _policy = Fixtures.Policies.create_policy(account_id: account.id)
      subject = api_client_subject(account, owner, "concurrent execution")
      runner = trusted_runner(account, owner)

      runbook =
        owner
        |> create_runbook(definition: definition(runner.group))
        |> Fixtures.Runbooks.publish_runbook()

      facts = mcp_execution_facts(runbook)

      results =
        1..8
        |> Enum.map(fn _index ->
          Task.async(fn -> Runbooks.create_or_replay_mcp_execution(facts, subject) end)
        end)
        |> Enum.map(&Task.await(&1, 5_000))

      assert Enum.count(results, &match?({:ok, :created, _execution}, &1)) == 1

      execution_ids =
        results |> Enum.map(fn {:ok, _outcome, execution} -> execution.id end) |> Enum.uniq()

      assert length(execution_ids) == 1
      assert Repo.aggregate(RunbookExecution, :count) == 1
      assert Repo.aggregate(MCPOperations.Operation, :count) == 1
    end

    test "rolls the reservation back when the fresh preflight fails" do
      {_user, account, owner} = Fixtures.Subjects.owner_subject()
      _policy = Fixtures.Policies.create_policy(account_id: account.id)
      subject = api_client_subject(account, owner, "failed preflight")
      runner = trusted_runner(account, owner)
      never_published = create_runbook(owner, definition: definition(runner.group))

      live =
        owner
        |> create_runbook(definition: definition(runner.group))
        |> Fixtures.Runbooks.publish_runbook()

      rejected = [
        {mcp_execution_facts(never_published, runbook_ref: "#{never_published.slug}@1"),
         :not_found},
        {mcp_execution_facts(live, runbook_ref: "#{live.slug}@2"), :not_live},
        {mcp_execution_facts(live, runbook_ref: "missing-runbook@1"), :not_found},
        {mcp_execution_facts(live, runbook_ref: "not a ref"), :invalid_runbook_ref},
        {mcp_execution_facts(live, reason: "  "), :reason_required}
      ]

      Enum.each(rejected, fn {facts, reason} ->
        assert Runbooks.create_or_replay_mcp_execution(facts, subject) == {:error, reason}

        refute Repo.exists?(RunbookExecution)
        refute Repo.exists?(MCPOperations.Operation)
      end)
    end

    test "denies a caller without dispatch permission and hides another account" do
      fixture = mcp_execution_fixture()
      facts = mcp_execution_facts(fixture.runbook)

      assert Runbooks.create_or_replay_mcp_execution(
               facts,
               membership_subject(fixture.account, :viewer)
             ) == {:error, :unauthorized}

      {_user, other_account, other_owner} = Fixtures.Subjects.owner_subject()
      other_subject = api_client_subject(other_account, other_owner, "foreign execution")

      assert Runbooks.create_or_replay_mcp_execution(facts, other_subject) ==
               {:error, :not_found}

      # Only the fixture's reservation survives: the rejected preflight rolled
      # the foreign account's own reservation back with it.
      assert Repo.aggregate(MCPOperations.Operation, :count) == 1
    end
  end

  describe "create_or_replay_mcp_execution/2 with allow_draft" do
    test "executes the exact consented draft through the scheduler and replays it" do
      {_user, account, owner} = Fixtures.Subjects.owner_subject()
      _policy = Fixtures.Policies.create_policy(account_id: account.id)
      subject = api_client_subject(account, owner, "draft test")
      runner = trusted_runner(account, owner)
      Runners.subscribe_runner_transport(runner)
      runbook = create_runbook(owner, slug: "draft-test", definition: definition(runner.group))

      facts =
        mcp_draft_execution_facts(runbook, reason: "test draft on the selected fleet")

      definition_sha256 = Runbooks.Definition.digest(runbook.draft_definition)

      assert {:ok, :created, execution} =
               Runbooks.create_or_replay_mcp_execution(facts, subject)

      assert execution.kind == :draft_test
      assert execution.definition_sha256 == definition_sha256
      assert execution.definition == runbook.draft_definition
      assert execution.runbook_version == nil

      assert execution.id ==
               MCPOperations.resource_id(facts.operation_id, :execute_runbook, subject)

      assert [%{runbook_step_id: "uptime"}] =
               Runs.list_runs_for_runbook_execution(account.id, execution.id)

      assert %{payload: payload} =
               Repo.get_by!(Emisar.Audit.Event,
                 event_type: "runbook.dispatched",
                 target_id: runbook.id
               )

      assert payload["execution_kind"] == "draft_test"
      assert payload["definition_sha256"] == definition_sha256

      assert {:ok, :replay, replayed} =
               Runbooks.create_or_replay_mcp_execution(facts, subject)

      assert replayed.id == execution.id
      assert Repo.aggregate(RunbookExecution, :count) == 1
    end

    test "hides another account's draft without persisting an operation" do
      {_user, account, owner} = Fixtures.Subjects.owner_subject()
      _policy = Fixtures.Policies.create_policy(account_id: account.id)
      runner = trusted_runner(account, owner)
      runbook = create_runbook(owner, slug: "draft-test", definition: definition(runner.group))

      {_other_user, other_account, other_owner} = Fixtures.Subjects.owner_subject()
      _other_policy = Fixtures.Policies.create_policy(account_id: other_account.id)
      other_subject = api_client_subject(other_account, other_owner, "foreign draft test")

      assert Runbooks.create_or_replay_mcp_execution(
               mcp_draft_execution_facts(runbook),
               other_subject
             ) == {:error, :draft_not_found}

      refute Repo.exists?(RunbookExecution)
      refute Repo.exists?(MCPOperations.Operation)
    end

    test "rejects a stale content digest and each missing authority" do
      {_user, account, owner} = Fixtures.Subjects.owner_subject()
      _policy = Fixtures.Policies.create_policy(account_id: account.id)
      subject = api_client_subject(account, owner, "draft test")
      runner = trusted_runner(account, owner)
      runbook = create_runbook(owner, slug: "draft-test", definition: definition(runner.group))

      assert Runbooks.create_or_replay_mcp_execution(
               mcp_draft_execution_facts(runbook,
                 definition_sha256: String.duplicate("0", 64)
               ),
               subject
             ) == {:error, :draft_changed}

      facts = mcp_draft_execution_facts(runbook)

      assert Runbooks.create_or_replay_mcp_execution(
               facts,
               without_permission(subject, Runbooks.Authorizer.draft_runbooks_permission())
             ) == {:error, :unauthorized}

      assert Runbooks.create_or_replay_mcp_execution(
               facts,
               without_permission(subject, Runs.Authorizer.dispatch_run_permission())
             ) == {:error, :unauthorized}

      # A draft is reachable only with explicit consent: default execution still
      # resolves live releases only.
      assert Runbooks.create_or_replay_mcp_execution(
               mcp_execution_facts(runbook, runbook_ref: "#{runbook.slug}@1"),
               subject
             ) == {:error, :not_found}

      refute Repo.exists?(RunbookExecution)
    end

    test "retains the whole-execution approval gate and draft-test identity" do
      {_user, account, owner} = Fixtures.Subjects.owner_subject()

      _policy =
        Fixtures.Policies.create_policy(
          account_id: account.id,
          rules: %{
            "schema_version" => 2,
            "defaults" => %{
              "low" => "require_approval",
              "medium" => "require_approval",
              "high" => "require_approval",
              "critical" => "deny"
            },
            "overrides" => [],
            "approval" => %{"min_approvals" => 1, "allow_self_approval" => false}
          }
        )

      subject = api_client_subject(account, owner, "draft approval")
      runner = trusted_runner(account, owner)

      runbook =
        create_runbook(owner, slug: "draft-approval", definition: definition(runner.group))

      assert {:ok, :created, execution} =
               Runbooks.create_or_replay_mcp_execution(
                 mcp_draft_execution_facts(runbook),
                 subject
               )

      assert execution.status == :pending_approval
      assert execution.kind == :draft_test
      assert Runs.list_runs_for_runbook_execution(account.id, execution.id) == []

      assert {:ok, request} =
               Approvals.fetch_request_for_visible_runbook_execution(execution, subject)

      assert request.context["execution_kind"] == "draft_test"
      assert get_in(request.context, ["runbook", "version"]) == nil

      assert get_in(request.context, ["runbook", "definition_sha256"]) ==
               execution.definition_sha256
    end
  end

  describe "resolve_plan/2" do
    test "returns the exact frozen blast radius without dispatching" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      _policy = Fixtures.Policies.create_policy(account_id: account.id)
      runner = trusted_runner(account, subject)

      runbook =
        subject
        |> create_runbook(definition: definition(runner.group))
        |> Fixtures.Runbooks.publish_runbook()

      assert {:ok, result} = Runbooks.resolve_plan(runbook, subject)
      assert result.total == 1
      assert result.stages == 1
      refute Repo.exists?(RunbookExecution)

      assert get_in(result.plan, ["stages", Access.at(0), "items", Access.at(0), "pack_ref"]) ==
               "linux-core@1.4.2/#{@pack_hash}"
    end
  end

  describe "resolve_plan/3" do
    test "binds typed input values and reports validation at the input path" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      _policy = Fixtures.Policies.create_policy(account_id: account.id)
      runner = trusted_runner(account, subject, args: [arg("seconds", "integer")])

      runbook =
        subject
        |> create_runbook(definition: input_definition(runner.group))
        |> Fixtures.Runbooks.publish_runbook()

      assert {:ok, result} = Runbooks.resolve_plan(runbook, %{"seconds" => 30}, subject)

      assert get_in(result.plan, ["stages", Access.at(0), "items", Access.at(0), "args"]) ==
               %{"seconds" => 30}

      assert {:error, [issue]} =
               Runbooks.resolve_plan(runbook, %{"seconds" => "thirty"}, subject)

      assert issue.path == "/input_values/seconds"
    end
  end

  describe "resolve_plan/4" do
    test "uses the same one-group runner for preview and dispatch" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      _policy = Fixtures.Policies.create_policy(account_id: account.id)
      trusted_runner(account, subject, group: "workers")
      trusted_runner(account, subject, group: "workers")

      definition =
        definition("workers")
        |> put_in(
          ["stages", Access.at(0), "steps", Access.at(0), "targets", "selection"],
          "random_one"
        )

      runbook =
        create_runbook(subject, definition: definition) |> Fixtures.Runbooks.publish_runbook()

      seed = Runbooks.new_target_selection_seed()

      assert {:ok, preview} = Runbooks.resolve_plan(runbook, %{}, seed, subject)

      assert {:ok, result} =
               Runbooks.dispatch_runbook(runbook, "inspect one worker", subject,
                 target_selection_seed: seed
               )

      preview_runner =
        get_in(preview.plan, ["stages", Access.at(0), "items", Access.at(0), "runner_ref"])

      assert preview_runner ==
               get_in(result.plan, [
                 "stages",
                 Access.at(0),
                 "items",
                 Access.at(0),
                 "runner_ref"
               ])

      assert %{target_selection: "random_one", target_group: "workers"} =
               ExecutionItem.Query.by_execution_id(result.execution_id) |> Repo.one!()
    end
  end

  describe "new_target_selection_seed/0" do
    test "returns independent opaque server seeds" do
      first = Runbooks.new_target_selection_seed()
      second = Runbooks.new_target_selection_seed()

      assert is_binary(first)
      assert byte_size(first) >= 32
      refute first == second
    end
  end

  describe "resolve_definition_plan/3" do
    test "compiles an unsaved definition through the caller's current scope" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = trusted_runner(account, subject)
      assert {:ok, runner_ref} = Runners.public_ref(runner)

      assert {:ok, %{total: 1, stages: 1, plan: plan}} =
               Runbooks.resolve_definition_plan(definition(runner.group), %{}, subject)

      assert get_in(plan, ["stages", Access.at(0), "items", Access.at(0), "runner_ref"]) ==
               runner_ref

      {_user, _account, other_subject} = Fixtures.Subjects.owner_subject()

      assert {:error, [_issue]} =
               Runbooks.resolve_definition_plan(definition(runner.group), %{}, other_subject)
    end
  end

  describe "cast_form_inputs/2" do
    test "applies a declared default to both the typed and the rendered values" do
      definition =
        definition_with_inputs([input("window", type: "integer", extra: %{"default" => 30})])

      assert {:ok, %{values: values, form_values: form_values}} =
               Runbooks.cast_form_inputs(definition, %{})

      assert values == %{"window" => 30}
      assert form_values == %{"window" => "30"}
    end

    test "omits a blank optional input while the form keeps what was supplied" do
      definition = definition_with_inputs([input("note", required: false)])

      assert {:ok, %{values: values, form_values: form_values}} =
               Runbooks.cast_form_inputs(definition, %{"note" => ""})

      assert values == %{}
      assert form_values == %{"note" => ""}
    end

    test "names a missing required input at its own path and field" do
      definition = definition_with_inputs([input("token")])

      assert {:error, %{issues: issues, field_errors: field_errors}} =
               Runbooks.cast_form_inputs(definition, %{"token" => ""})

      assert issues == [
               %{
                 code: "invalid_input",
                 path: "/input_values/token",
                 message: "Required input is missing."
               }
             ]

      assert field_errors == %{"token" => "Required input is missing."}
    end

    test "casts an integer only from a fully consumed string" do
      definition = definition_with_inputs([input("window", type: "integer")])

      assert {:ok, %{values: %{"window" => 30}}} =
               Runbooks.cast_form_inputs(definition, %{"window" => "30"})

      assert {:error, %{field_errors: field_errors}} =
               Runbooks.cast_form_inputs(definition, %{"window" => "30 seconds"})

      assert field_errors == %{"window" => "Enter a whole number."}
    end

    test "casts a number only from a fully consumed string" do
      definition = definition_with_inputs([input("ratio", type: "number")])

      assert {:ok, %{values: %{"ratio" => 1.5}}} =
               Runbooks.cast_form_inputs(definition, %{"ratio" => "1.5"})

      assert {:error, %{field_errors: field_errors}} =
               Runbooks.cast_form_inputs(definition, %{"ratio" => "1.5x"})

      assert field_errors == %{"ratio" => "Enter a number."}
    end

    test "rejects a magnitude no float can hold" do
      definition = definition_with_inputs([input("ratio", type: "number")])

      assert {:error, %{field_errors: field_errors}} =
               Runbooks.cast_form_inputs(definition, %{"ratio" => "1e400"})

      assert field_errors == %{"ratio" => "Enter a number."}
    end

    test "an unreadable value never falls back to the declared default" do
      definition =
        definition_with_inputs([input("window", type: "integer", extra: %{"default" => 30})])

      assert {:error, %{field_errors: field_errors}} =
               Runbooks.cast_form_inputs(definition, %{"window" => "soon"})

      assert field_errors == %{"window" => "Enter a whole number."}
    end

    test "casts a boolean from the two options the control renders" do
      definition = definition_with_inputs([input("verbose", type: "boolean")])

      assert {:ok, %{values: %{"verbose" => true}}} =
               Runbooks.cast_form_inputs(definition, %{"verbose" => "true"})

      assert {:ok, %{values: %{"verbose" => false}}} =
               Runbooks.cast_form_inputs(definition, %{"verbose" => "false"})

      assert {:error, %{field_errors: field_errors}} =
               Runbooks.cast_form_inputs(definition, %{"verbose" => "yes"})

      assert field_errors == %{"verbose" => "Choose true or false."}
    end

    test "casts an enum from its declared members only" do
      definition =
        definition_with_inputs([
          input("mode", type: "enum", extra: %{"enum" => ["fast", "safe"]})
        ])

      assert {:ok, %{values: %{"mode" => "safe"}}} =
               Runbooks.cast_form_inputs(definition, %{"mode" => "safe"})

      assert {:error, %{field_errors: field_errors}} =
               Runbooks.cast_form_inputs(definition, %{"mode" => "reckless"})

      assert field_errors == %{"mode" => "Choose an allowed value."}
    end

    test "carries a sensitive value into the typed values and never into an error" do
      definition =
        definition_with_inputs([
          input("token", sensitive: true),
          input("window", type: "integer")
        ])

      assert {:ok, %{values: values}} =
               Runbooks.cast_form_inputs(definition, %{"token" => "s3cr3t", "window" => "30"})

      assert values == %{"token" => "s3cr3t", "window" => 30}

      assert {:error, %{issues: issues, field_errors: field_errors}} =
               Runbooks.cast_form_inputs(definition, %{"token" => "s3cr3t", "window" => "soon"})

      assert field_errors == %{"window" => "Enter a whole number."}
      refute inspect({issues, field_errors}) =~ "s3cr3t"
    end

    test "rejects an undeclared key and leaves it out of the rendered values" do
      definition = definition_with_inputs([input("note", required: false)])
      supplied = %{"note" => "checked", "sneaky" => "x"}

      assert {:error, %{issues: issues, field_errors: field_errors, form_values: form_values}} =
               Runbooks.cast_form_inputs(definition, supplied)

      assert issues == [
               %{
                 code: "invalid_input",
                 path: "/input_values/sneaky",
                 message: "Input is not declared by this runbook."
               }
             ]

      assert field_errors == %{}
      assert form_values == %{"note" => "checked"}
    end

    test "rejects a non-object form without raising" do
      definition = definition_with_inputs([input("window", type: "integer")])

      assert {:error, %{issues: issues, field_errors: %{}, form_values: form_values}} =
               Runbooks.cast_form_inputs(definition, "not-an-object")

      assert issues == [
               %{
                 code: "invalid_input",
                 path: "/input_values",
                 message: "Input values must be an object."
               }
             ]

      assert form_values == %{"window" => nil}
    end

    test "keeps nested hostile values out of the rendered form" do
      definition = definition_with_inputs([input("window", type: "integer")])

      assert {:error, %{field_errors: field_errors, form_values: form_values}} =
               Runbooks.cast_form_inputs(definition, %{"window" => %{"nested" => "value"}})

      assert field_errors == %{
               "window" => "Input does not satisfy its declared type and constraints."
             }

      assert form_values == %{"window" => nil}
    end

    test "inherits the compiler's declared constraints" do
      definition = definition_with_inputs([input("name", extra: %{"min_length" => 4})])

      assert {:error, %{field_errors: field_errors}} =
               Runbooks.cast_form_inputs(definition, %{"name" => "ab"})

      assert field_errors == %{
               "name" => "Input does not satisfy its declared type and constraints."
             }
    end

    test "reports an invalid definition with no field errors or rendered values" do
      assert {:error, %{issues: [issue | _], field_errors: %{}, form_values: %{}}} =
               Runbooks.cast_form_inputs(%{"schema_version" => 1}, %{})

      assert issue.code == "invalid_definition"
    end

    test "orders issues by path and addresses each failing field" do
      definition =
        definition_with_inputs([
          input("beta", type: "integer"),
          input("alpha", type: "integer")
        ])

      assert {:error, %{issues: issues, field_errors: field_errors}} =
               Runbooks.cast_form_inputs(definition, %{"beta" => "b", "alpha" => "a"})

      assert Enum.map(issues, & &1.path) == ["/input_values/alpha", "/input_values/beta"]

      assert field_errors == %{
               "alpha" => "Enter a whole number.",
               "beta" => "Enter a whole number."
             }
    end
  end

  describe "editor_projection/1" do
    test "projects the online fleet and the trusted actions it can execute" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = trusted_runner(account, subject)
      _offline = trusted_runner(account, subject, connected?: false, group: "cold")

      assert {:ok, projection} = Runbooks.editor_projection(subject)
      assert {:ok, runner_ref} = Runners.public_ref(runner)

      assert [target] = projection.targets

      assert target == %{
               id: runner.id,
               runner_ref: runner_ref,
               name: runner.name,
               group: "database"
             }

      assert Map.keys(projection.catalog.candidates) == [{"linux-core", "linux.uptime"}]
    end

    test "another account's fleet and catalog stay out of the projection" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      trusted_runner(account, subject)

      {_user, _other_account, other_subject} = Fixtures.Subjects.owner_subject()

      assert {:ok, projection} = Runbooks.editor_projection(other_subject)
      assert projection.targets == []
      assert projection.catalog.candidates == %{}
    end

    test "a subject without view_runbooks is denied" do
      {_user, account, _subject} = Fixtures.Subjects.owner_subject()
      no_view = %Subject{account: account, role: :runner, permissions: MapSet.new()}

      assert Runbooks.editor_projection(no_view) == {:error, :unauthorized}
    end
  end

  describe "editor_target_runners/3" do
    test "resolves a group, an exact runner, and one random group member" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      first = trusted_runner(account, subject, group: "workers")
      second = trusted_runner(account, subject, group: "workers")

      assert {:ok, projection} = Runbooks.editor_projection(subject)
      assert {:ok, first_ref} = Runners.public_ref(first)

      assert {:ok, all} = Runbooks.editor_target_runners(projection, ["group:workers"], "all")
      assert Enum.map(all, & &1.id) |> Enum.sort() == Enum.sort([first.id, second.id])

      assert {:ok, [exact]} =
               Runbooks.editor_target_runners(projection, ["runner:" <> first_ref], "all")

      assert exact.id == first.id

      # The whole possible group is the target set — the member is sampled at
      # dispatch, so the editor must judge every one of them.
      assert {:ok, random} =
               Runbooks.editor_target_runners(projection, ["group:workers"], "random_one")

      assert Enum.map(random, & &1.id) |> Enum.sort() == Enum.sort([first.id, second.id])
    end

    test "an offline, unknown, or malformed selection does not resolve" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      offline = trusted_runner(account, subject, connected?: false)
      assert {:ok, offline_ref} = Runners.public_ref(offline)
      assert {:ok, projection} = Runbooks.editor_projection(subject)

      for {refs, selection} <- [
            {["group:database"], "all"},
            {["runner:" <> offline_ref], "all"},
            {["group:absent"], "all"},
            {[], "all"},
            {["group:database", "group:database"], "random_one"},
            {["runner:" <> offline_ref], "random_one"},
            {["group:database"], "sideways"}
          ] do
        assert Runbooks.editor_target_runners(projection, refs, selection) ==
                 {:error, :unknown_target}
      end
    end
  end

  describe "editor_actions/3" do
    test "offers an action every selected runner supports at its own exact version" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      _policy = Fixtures.Policies.create_policy(account_id: account.id)
      trusted_runner(account, subject, group: "workers", version: "1.4.2")
      trusted_runner(account, subject, group: "workers", version: "1.5.0")

      assert {:ok, projection} = Runbooks.editor_projection(subject)

      assert [action] = Runbooks.editor_actions(projection, ["group:workers"], "all")
      assert action.pack_id == "linux-core"
      assert action.action_id == "linux.uptime"
      assert action.risk == "low"

      # The compiler agrees the same authored step is currently dispatchable.
      assert {:ok, _preview} =
               Runbooks.preview_definition_plan(definition("workers"), subject)
    end

    test "runners exposing different risk make the action unavailable, as the compiler does" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      _policy = Fixtures.Policies.create_policy(account_id: account.id)
      trusted_runner(account, subject, group: "workers", version: "1.4.2")
      trusted_runner(account, subject, group: "workers", version: "2.0.0", risk: "critical")

      assert {:ok, projection} = Runbooks.editor_projection(subject)

      assert Runbooks.editor_actions(projection, ["group:workers"], "all") == []

      assert {:error, issues} =
               Runbooks.preview_definition_plan(definition("workers"), subject)

      assert Enum.any?(issues, &(&1.code == "incompatible_action_contracts"))
    end

    test "runners exposing different arguments make the action unavailable" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      trusted_runner(account, subject, group: "workers", version: "1.4.2")

      trusted_runner(account, subject,
        group: "workers",
        version: "2.0.0",
        args: [arg("seconds", "integer")]
      )

      assert {:ok, projection} = Runbooks.editor_projection(subject)
      assert Runbooks.editor_actions(projection, ["group:workers"], "all") == []
    end

    test "an untrusted deployment on one selected runner narrows the group, never blocks it" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      _policy = Fixtures.Policies.create_policy(account_id: account.id)
      trusted = trusted_runner(account, subject, group: "workers", version: "1.4.2")

      untrusted =
        trusted_runner(account, subject, group: "workers", version: "9.9.9", trust?: false)

      assert {:ok, projection} = Runbooks.editor_projection(subject)
      assert {:ok, trusted_ref} = Runners.public_ref(trusted)
      assert {:ok, untrusted_ref} = Runners.public_ref(untrusted)

      assert [_action] =
               Runbooks.editor_actions(projection, ["runner:" <> trusted_ref], "all")

      assert Runbooks.editor_actions(projection, ["runner:" <> untrusted_ref], "all") == []

      assert [action] = Runbooks.editor_actions(projection, ["group:workers"], "all")
      assert action.action_id == "linux.uptime"

      # The compiler agrees: the authored step dispatches to the trusted runner only.
      assert {:ok, preview} =
               Runbooks.preview_definition_plan(definition("workers"), subject)

      assert preview.total == 1

      assert [%{"runner_ref" => ^trusted_ref}] =
               get_in(preview.plan, ["stages", Access.at(0), "items"])
    end

    test "unresolved targets offer no action at all" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      trusted_runner(account, subject)

      assert {:ok, projection} = Runbooks.editor_projection(subject)
      assert Runbooks.editor_actions(projection, [], "all") == []
      assert Runbooks.editor_actions(projection, ["group:absent"], "all") == []
    end
  end

  describe "editor_action/5" do
    test "carries the trusted descriptor's arguments and risk" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      trusted_runner(account, subject, args: [arg("seconds", "integer")])

      assert {:ok, projection} = Runbooks.editor_projection(subject)

      assert {:ok, action} =
               Runbooks.editor_action(
                 projection,
                 ["group:database"],
                 "all",
                 "linux-core",
                 "linux.uptime"
               )

      assert action.risk == "low"
      assert [%{"name" => "seconds", "type" => "integer"}] = action.args
    end

    test "a stale saved choice resolves to nothing, so it carries no risk or arguments" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      trusted_runner(account, subject)

      assert {:ok, projection} = Runbooks.editor_projection(subject)

      assert Runbooks.editor_action(
               projection,
               ["group:database"],
               "all",
               "linux-core",
               "linux.retired"
             ) == {:error, :not_found}
    end
  end

  describe "validate_definition/2" do
    test "returns the canonical definition and rejects malformed stages before preflight" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      definition = definition()

      assert {:ok, ^definition} = Runbooks.validate_definition(definition, subject)

      assert {:error, issues} =
               Runbooks.validate_definition(%{"schema_version" => 1, "stages" => []}, subject)

      assert Enum.any?(issues, &(&1.code == "invalid_definition" and &1.path == "/stages"))
    end

    test "a subject without view_runbooks is denied" do
      {_user, account, _subject} = Fixtures.Subjects.owner_subject()
      no_view = Fixtures.Subjects.build_subject(account: account, role: :runner)

      assert Runbooks.validate_definition(definition(), no_view) == {:error, :unauthorized}
    end
  end

  describe "preview_definition_plan/2" do
    test "uses deterministic placeholders for required unsaved inputs" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = trusted_runner(account, subject, args: [arg("seconds", "integer")])

      assert {:ok, %{total: 1, plan: plan}} =
               Runbooks.preview_definition_plan(input_definition(runner.group), subject)

      assert get_in(plan, ["stages", Access.at(0), "items", Access.at(0), "args", "seconds"]) ==
               0
    end
  end

  describe "cancel_execution/2" do
    test "cancels a visible active execution and hides cross-account ids" do
      fixture = mcp_execution_fixture()

      assert {:ok, cancelled} =
               Runbooks.cancel_execution(fixture.execution_id, fixture.owner)

      assert cancelled.status == :cancelled

      {_user, _account, other_subject} = Fixtures.Subjects.owner_subject()

      assert Runbooks.cancel_execution(fixture.execution_id, other_subject) ==
               {:error, :not_found}
    end
  end

  describe "action_run_settled/1" do
    test "treats stale or unrelated callbacks as an idempotent no-op" do
      assert :noop = Runbooks.action_run_settled(%Runs.ActionRun{})
    end
  end

  describe "approval_settled/1" do
    test "treats a missing execution callback as idempotent success" do
      assert :ok = Runbooks.approval_settled(Ecto.UUID.generate())
    end
  end

  describe "recheck_execution_approval/1" do
    test "fails closed when the execution is missing" do
      assert Runbooks.recheck_execution_approval(Ecto.UUID.generate()) ==
               {:error, :runbook_execution_not_approvable}
    end
  end

  describe "runner_ids_for_execution_approval/2" do
    test "fails closed for missing and malformed account-scoped executions" do
      assert Runbooks.runner_ids_for_execution_approval(
               Ecto.UUID.generate(),
               Ecto.UUID.generate()
             ) == {:error, :not_found}

      assert Runbooks.runner_ids_for_execution_approval("bad", "bad") ==
               {:error, :not_found}
    end
  end

  describe "activate_pending_approval/2" do
    test "activates the exact pending execution inside the caller transaction" do
      {user, account, _subject} = Fixtures.Subjects.owner_subject()
      request = Fixtures.Approvals.create_execution_request(account, user)

      assert {:ok, {:ok, activated}} =
               Repo.transaction(fn ->
                 Runbooks.activate_pending_approval(Repo, request.runbook_execution_id)
               end)

      assert activated.status == :active
    end
  end

  describe "lock_pending_approval/2" do
    test "rejects a missing execution inside the caller's transaction boundary" do
      assert Runbooks.lock_pending_approval(Repo, Ecto.UUID.generate()) ==
               {:error, :runbook_execution_not_approvable}
    end
  end

  describe "halt_pending_approval_in_multi/4" do
    test "halts the execution and every pending stage in one transaction" do
      {user, account, _subject} = Fixtures.Subjects.owner_subject()
      request = Fixtures.Approvals.create_execution_request(account, user)

      assert {:ok, _changes} =
               Multi.new()
               |> Runbooks.halt_pending_approval_in_multi(
                 request.runbook_execution_id,
                 "approval_denied",
                 "Approval denied."
               )
               |> Repo.transaction()

      assert fetch_execution(request.runbook_execution_id).status == :halted
    end
  end

  describe "attempt_identity_current?/2" do
    test "accepts only the exact current logical attempt identity" do
      fixture = mcp_execution_fixture()

      assert [attempt] =
               Runs.list_runs_for_runbook_execution(fixture.account.id, fixture.execution_id)

      item =
        ExecutionItem.Query.by_id(attempt.runbook_execution_item_id)
        |> Repo.one!()

      attrs = %{
        runbook_execution_item_id: item.id,
        runbook_execution_id: item.runbook_execution_id,
        runbook_execution_stage_id: item.runbook_execution_stage_id,
        runner_id: item.runner_id,
        action_id: item.action_id,
        pack_ref: item.pack_ref,
        runbook_pack_hash: item.pack_hash,
        attempt_number: item.attempt_count
      }

      assert Runbooks.attempt_identity_current?(attrs, fixture.account.id)
      refute Runbooks.attempt_identity_current?(%{attrs | attempt_number: 2}, fixture.account.id)
      refute Runbooks.attempt_identity_current?(attrs, Ecto.UUID.generate())
    end
  end

  describe "ensure_attempt_approvable/2" do
    test "rejects a runbook attempt whose durable parent rows are missing" do
      attempt = %Runs.ActionRun{
        source: :runbook,
        runbook_execution_id: Ecto.UUID.generate(),
        runbook_execution_item_id: Ecto.UUID.generate(),
        attempt_number: 1
      }

      assert Runbooks.ensure_attempt_approvable(Repo, attempt) ==
               {:error, :runbook_attempt_not_approvable}
    end
  end

  describe "recover_due/0" do
    test "returns the bounded number of active executions visited" do
      assert Runbooks.recover_due() == 0
    end
  end

  describe "subject_can_view_runbooks?/1" do
    test "reflects the subject's permissions" do
      {_user, account, owner} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      assert Runbooks.subject_can_view_runbooks?(owner)
      refute Runbooks.subject_can_view_runbooks?(Subject.for_runner(runner, account))
    end
  end

  describe "subject_can_manage_runbooks?/1" do
    test "distinguishes owners from viewers" do
      {_user, account, owner} = Fixtures.Subjects.owner_subject()
      viewer = membership_subject(account, "viewer")

      assert Runbooks.subject_can_manage_runbooks?(owner)
      refute Runbooks.subject_can_manage_runbooks?(viewer)
    end
  end

  describe "subject_can_cancel_execution?/1" do
    test "distinguishes operators from viewers" do
      {_user, account, _owner} = Fixtures.Subjects.owner_subject()
      operator = membership_subject(account, "operator")
      viewer = membership_subject(account, "viewer")

      assert Runbooks.subject_can_cancel_execution?(operator)
      refute Runbooks.subject_can_cancel_execution?(viewer)
    end
  end

  defp create_runbook(subject, opts \\ []) do
    assert {:ok, runbook} = Runbooks.create_runbook(runbook_attrs(opts), subject)
    runbook
  end

  defp delete(runbook, subject) do
    assert {:ok, deleted} = Runbooks.delete_runbook(runbook, subject)
    deleted
  end

  defp mcp_draft_facts(opts \\ []) do
    %{
      operation_id: Keyword.get(opts, :operation_id, operation_id()),
      title: Keyword.get(opts, :title, "Agent draft"),
      slug: Keyword.get(opts, :slug, "agent-draft"),
      description: Keyword.get(opts, :description),
      definition: Keyword.get(opts, :definition, definition())
    }
  end

  defp mcp_execution_facts(runbook, opts \\ []) do
    %{
      operation_id: Keyword.get(opts, :operation_id, operation_id()),
      runbook_ref: Keyword.get(opts, :runbook_ref, "#{runbook.slug}@#{runbook.live_version}"),
      allow_draft: false,
      reason: Keyword.get(opts, :reason, "inspect fleet"),
      input_values: Keyword.get(opts, :input_values, %{})
    }
  end

  defp mcp_draft_execution_facts(runbook, opts \\ []) do
    %{
      operation_id: Keyword.get(opts, :operation_id, operation_id()),
      slug: Keyword.get(opts, :slug, runbook.slug),
      definition_sha256:
        Keyword.get_lazy(opts, :definition_sha256, fn ->
          Runbooks.Definition.digest(runbook.draft_definition)
        end),
      allow_draft: true,
      reason: Keyword.get(opts, :reason, "inspect fleet"),
      input_values: Keyword.get(opts, :input_values, %{})
    }
  end

  defp mcp_draft_update_facts(runbook, opts \\ []) do
    %{
      operation_id: Keyword.get(opts, :operation_id, operation_id()),
      slug: runbook.slug,
      definition_sha256: base_sha(runbook),
      title: Keyword.get(opts, :title, runbook.title),
      description: Keyword.get(opts, :description, runbook.description),
      definition: Keyword.get(opts, :definition, runbook.draft_definition || runbook.definition)
    }
  end

  defp runbook_attrs(opts \\ []) do
    %{
      "title" => Keyword.get(opts, :title, "Runbook #{System.unique_integer([:positive])}"),
      "slug" => Keyword.get(opts, :slug, "runbook-#{System.unique_integer([:positive])}"),
      "description" => Keyword.get(opts, :description),
      "draft_definition" => Keyword.get(opts, :definition, definition())
    }
  end

  # The digest a save must carry back: the unpublished change when there is one,
  # else the live release.
  defp base_sha(runbook),
    do: Runbooks.definition_digest(runbook.draft_definition || runbook.definition)

  defp save_draft(runbook, attrs, subject) do
    Runbooks.save_draft(runbook, attrs, base_sha(runbook), subject)
  end

  defp definition(group \\ "database")

  defp definition(group) when is_binary(group),
    do: definition([stage("inspect", [step("uptime", group)])])

  defp definition(stages) when is_list(stages) do
    %{
      "schema_version" => 1,
      "context_markdown" => "Inspect the selected systems.",
      "inputs" => [],
      "stages" => stages
    }
  end

  defp input_definition(group) do
    definition(group)
    |> Map.put("inputs", [
      %{
        "id" => "seconds",
        "description" => "Observation window",
        "type" => "integer",
        "required" => true,
        "sensitive" => false
      }
    ])
    |> put_in(
      ["stages", Access.at(0), "steps", Access.at(0), "args"],
      %{"seconds" => %{"source" => "input", "ref" => "seconds"}}
    )
  end

  defp definition_with_inputs(inputs), do: Map.put(definition(), "inputs", inputs)

  defp input(id, opts \\ []) do
    Map.merge(
      %{
        "id" => id,
        "description" => "A run-time value",
        "type" => Keyword.get(opts, :type, "string"),
        "required" => Keyword.get(opts, :required, true),
        "sensitive" => Keyword.get(opts, :sensitive, false)
      },
      Keyword.get(opts, :extra, %{})
    )
  end

  # A definition whose single stage runs exactly the named actions, one step
  # each — the shape the list page's risk fold reads.
  defp risk_definition(action_ids) do
    steps =
      Enum.with_index(action_ids, fn action_id, index ->
        "step-#{index}" |> step("database") |> Map.put("action", action_id)
      end)

    definition([stage("inspect", steps)])
  end

  defp stage(id, steps) do
    %{
      "id" => id,
      "title" => String.capitalize(id),
      "mode" => "sequential",
      "steps" => steps
    }
  end

  defp step(id, group) do
    %{
      "id" => id,
      "pack" => %{"id" => "linux-core"},
      "action" => "linux.uptime",
      "targets" => %{"selection" => "all", "refs" => ["group:" <> group]},
      "args" => %{},
      "outputs" => [],
      "success" => [],
      "wait" => nil
    }
  end

  defp arg(name, type) do
    %{
      "name" => name,
      "type" => type,
      "required" => true,
      "sensitive" => false
    }
  end

  defp trusted_runner(account, subject, opts \\ []) do
    runner =
      Fixtures.Runners.create_runner(
        account_id: account.id,
        group: Keyword.get(opts, :group, "database"),
        connected?: Keyword.get(opts, :connected?, true)
      )

    assert {:ok, runner} =
             Catalog.observe_state(runner, %{
               "hostname" => runner.hostname,
               "version" => runner.runner_version,
               "labels" => runner.labels,
               "enforce_signatures" => false,
               "packs" => %{
                 "linux-core" => %{
                   "version" => Keyword.get(opts, :version, "1.4.2"),
                   "hash" =>
                     Fixtures.Catalog.pack_hash(
                       "linux-core-#{Keyword.get(opts, :version, "1.4.2")}"
                     )
                 }
               },
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
                   "search_terms" => [],
                   "output_schema" => nil
                 }
               ]
             })

    if Keyword.get(opts, :trust?, true), do: trust_pack_versions(subject)

    runner
  end

  defp trust_pack_versions(subject) do
    assert {:ok, versions} = Catalog.list_all_pack_versions_for_account(subject)

    Enum.each(versions, fn version ->
      if version.trust_state != :trusted do
        assert {:ok, _trusted} = Catalog.trust_pack_version(version.id, subject)
      end
    end)
  end

  defp api_client_subject(account, owner, name) do
    assert {:ok, _raw, key} = Emisar.ApiKeys.create_key(%{name: name}, owner)
    Subject.for_api_key(key, account)
  end

  # The api_client role holds draft and dispatch authority together, so each
  # gate is proven by taking exactly one permission off a real MCP subject.
  defp without_permission(%Subject{} = subject, permission),
    do: %{subject | permissions: MapSet.delete(subject.permissions, permission)}

  defp membership_subject(account, role) do
    user = Fixtures.Users.create_user()

    membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: role
      )

    Fixtures.Subjects.membership_subject(membership)
  end

  defp mcp_execution_fixture do
    {_user, account, owner} = Fixtures.Subjects.owner_subject()
    _policy = Fixtures.Policies.create_policy(account_id: account.id)
    subject = api_client_subject(account, owner, "execution client")
    runner = trusted_runner(account, owner)
    Runners.subscribe_runner_transport(runner)

    runbook =
      owner
      |> create_runbook(definition: definition(runner.group))
      |> Fixtures.Runbooks.publish_runbook()

    facts = mcp_execution_facts(runbook)

    assert {:ok, :created, execution} =
             Runbooks.create_or_replay_mcp_execution(facts, subject)

    %{
      account: account,
      execution_id: execution.id,
      operation_id: facts.operation_id,
      owner: owner,
      runbook: runbook,
      runner: runner,
      subject: subject
    }
  end

  # The projection is pure, so unpersisted rows reach every branch without a
  # dispatch per case.
  defp projected_result(opts) do
    stages = Keyword.get(opts, :stages, [])

    execution = %RunbookExecution{
      id: Ecto.UUID.generate(),
      status: Keyword.get(opts, :status, :active),
      terminal_code: Keyword.get(opts, :terminal_code),
      terminal_message: Keyword.get(opts, :terminal_message),
      stages: stages,
      items: Enum.flat_map(stages, & &1.items)
    }

    %{execution: execution, latest_attempts: Keyword.get(opts, :latest_attempts, [])}
  end

  defp projected_stage(opts) do
    %ExecutionStage{
      id: Ecto.UUID.generate(),
      stage_id: Keyword.get(opts, :stage_id, "inspect"),
      title: "Inspect",
      position: Keyword.get(opts, :position, 0),
      mode: :sequential,
      max_parallel: 1,
      status: Keyword.get(opts, :status, :active),
      items: []
    }
  end

  defp projected_item(%ExecutionStage{} = stage, opts) do
    %ExecutionItem{
      id: Ecto.UUID.generate(),
      runbook_execution_stage_id: stage.id,
      stage_position: stage.position,
      step_id: Keyword.get(opts, :step_id, "uptime"),
      step_position: Keyword.get(opts, :step_position, 0),
      runner_ref: Keyword.get(opts, :runner_ref, runner_ref("a")),
      status: Keyword.get(opts, :status, :pending),
      attempt_count: Keyword.get(opts, :attempt_count, 0),
      output_plan: Keyword.get(opts, :output_plan, []),
      success_plan: Keyword.get(opts, :success_plan, []),
      outputs: Keyword.get(opts, :outputs, %{}),
      success_evidence: Keyword.get(opts, :success_evidence, []),
      terminal_code: Keyword.get(opts, :terminal_code),
      terminal_message: Keyword.get(opts, :terminal_message)
    }
  end

  defp runner_ref(name), do: "db-#{name}~" <> String.duplicate("f", 32)

  defp fetch_execution(id) do
    RunbookExecution.Query.by_id(id)
    |> Repo.fetch!(RunbookExecution.Query)
  end

  defp operation_id do
    "op_144NN9NMDZ1T76NARWCKM5A0D6"
  end
end
