defmodule Emisar.RunbooksTest do
  use Emisar.DataCase, async: true
  alias Ecto.Multi
  alias Emisar.Auth.Subject
  alias Emisar.Catalog
  alias Emisar.Fixtures
  alias Emisar.MCPOperations
  alias Emisar.Repo
  alias Emisar.Runbooks
  alias Emisar.Runbooks.{ExecutionItem, RunbookExecution}
  alias Emisar.Runners
  alias Emisar.Runs

  @pack_hash "sha256:" <> String.duplicate("a", 64)

  describe "list_runbooks/2" do
    test "lists only visible runbooks and applies filters" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      draft = create_runbook(subject, title: "Draft")
      published = create_runbook(subject, title: "Published") |> publish(subject)
      {_user, _account, other_subject} = Fixtures.Subjects.owner_subject()
      _other = create_runbook(other_subject, title: "Other")

      assert {:ok, runbooks, _metadata} =
               Runbooks.list_runbooks(subject, filter: [status: ["published"]])

      assert Enum.map(runbooks, & &1.id) == [published.id]
      refute draft.id in Enum.map(runbooks, & &1.id)
    end

    test "denies a principal without view permission" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      assert Runbooks.list_runbooks(Subject.for_runner(runner, account)) ==
               {:error, :unauthorized}
    end
  end

  describe "list_all_runbooks/1" do
    test "returns every visible non-deleted version" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      first = create_runbook(subject)
      assert {:ok, second} = Runbooks.save_new_version(first, %{"description" => "v2"}, subject)
      {_user, _account, other_subject} = Fixtures.Subjects.owner_subject()
      _other = create_runbook(other_subject)

      assert {:ok, runbooks} = Runbooks.list_all_runbooks(subject)
      assert MapSet.new(runbooks, & &1.id) == MapSet.new([first.id, second.id])
    end

    test "denies a principal without view permission" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      assert Runbooks.list_all_runbooks(Subject.for_runner(runner, account)) ==
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

  describe "fetch_published_runbook/2" do
    test "resolves the latest published version by slug or exact id" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      first = create_runbook(subject, slug: "health-check") |> publish(subject)

      assert {:ok, second_draft} =
               Runbooks.save_new_version(first, %{"description" => "new"}, subject)

      second = publish(second_draft, subject)

      assert {:ok, by_slug} = Runbooks.fetch_published_runbook("health-check", subject)
      assert by_slug.id == second.id
      assert {:ok, by_id} = Runbooks.fetch_published_runbook(first.id, subject)
      assert by_id.id == first.id
    end

    test "hides drafts and rows from another account" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      draft = create_runbook(subject, slug: "draft-only")
      {_user, _account, other_subject} = Fixtures.Subjects.owner_subject()
      other = create_runbook(other_subject, slug: "other") |> publish(other_subject)

      assert Runbooks.fetch_published_runbook(draft.id, subject) == {:error, :not_found}
      assert Runbooks.fetch_published_runbook(other.id, subject) == {:error, :not_found}
    end
  end

  describe "fetch_published_runbook_version/3" do
    test "returns only the exact visible published version" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      first = create_runbook(subject, slug: "versioned") |> publish(subject)

      assert {:ok, second_draft} =
               Runbooks.save_new_version(first, %{"description" => "new"}, subject)

      second = publish(second_draft, subject)

      assert {:ok, fetched} =
               Runbooks.fetch_published_runbook_version("versioned", 1, subject)

      assert fetched.id == first.id
      assert second.version == 2

      assert Runbooks.fetch_published_runbook_version("versioned", 3, subject) ==
               {:error, :not_found}

      {_user, _account, other_subject} = Fixtures.Subjects.owner_subject()

      assert Runbooks.fetch_published_runbook_version("versioned", 1, other_subject) ==
               {:error, :not_found}
    end
  end

  describe "fetch_mcp_draft_by_operation/2" do
    test "recovers only the current credential lineage" do
      {_user, account, owner} = Fixtures.Subjects.owner_subject()
      subject = api_client_subject(account, owner, "draft client")
      operation_id = operation_id()
      fingerprint = String.duplicate("b", 64)

      assert {:ok, :created, draft} =
               Runbooks.create_mcp_draft(
                 runbook_attrs(title: "MCP draft"),
                 operation_id,
                 fingerprint,
                 subject
               )

      assert {:ok, fetched} = Runbooks.fetch_mcp_draft_by_operation(operation_id, subject)
      assert fetched.id == draft.id

      other_subject = api_client_subject(account, owner, "other client")

      assert Runbooks.fetch_mcp_draft_by_operation(operation_id, other_subject) ==
               {:error, :not_found}
    end
  end

  describe "fetch_execution_by_operation/2" do
    test "recovers only the current credential lineage" do
      fixture = mcp_execution_fixture()

      assert {:ok, fetched} =
               Runbooks.fetch_execution_by_operation(fixture.operation_id, fixture.subject)

      assert fetched.id == fixture.execution_id

      other_subject = api_client_subject(fixture.account, fixture.owner, "other execution client")

      assert Runbooks.fetch_execution_by_operation(fixture.operation_id, other_subject) ==
               {:error, :not_found}
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

  describe "fetch_latest_execution_for_runbook/2" do
    test "returns the newest execution only while its complete runner set remains visible" do
      fixture = mcp_execution_fixture()

      assert {:ok, result} =
               Runbooks.fetch_latest_execution_for_runbook(
                 fixture.runbook,
                 fixture.subject
               )

      assert result.execution.id == fixture.execution_id

      fixture.account.id
      |> Fixtures.Memberships.fetch_membership(fixture.owner.actor.id)
      |> Fixtures.Memberships.force_runner_access(Emisar.Accounts.RunnerAccess.none())

      assert Runbooks.fetch_latest_execution_for_runbook(
               fixture.runbook,
               fixture.subject
             ) == {:error, :not_found}
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
    test "creates a bounded draft, derives its slug, audits it, and ignores status" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      Runbooks.subscribe_account_runbooks(account.id)
      attrs = runbook_attrs(title: "Database Health", slug: "", status: "published")

      assert {:ok, runbook} = Runbooks.create_runbook(attrs, subject)
      assert runbook.status == :draft
      assert runbook.slug == "database-health"
      assert runbook.definition == definition()
      assert_receive {:list_changed, :runbook, "runbook.created", runbook_id}
      assert runbook_id == runbook.id

      created_event =
        Emisar.Audit.Event
        |> Repo.all()
        |> Enum.find(&(&1.event_type == "runbook.created" and &1.target_id == runbook.id))

      assert created_event.target_id == runbook.id
    end

    test "persists incomplete drafts but keeps publication on the strict contract" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()

      incomplete =
        definition()
        |> put_in(["stages", Access.at(0), "steps", Access.at(0), "action"], "")

      attrs = runbook_attrs(title: "Work in progress", definition: incomplete)
      assert {:ok, draft} = Runbooks.create_runbook(attrs, subject)
      assert draft.status == :draft
      assert draft.definition == incomplete

      assert {:error, published_changeset} =
               Runbooks.create_published_runbook(attrs, subject)

      assert "Definition value has an invalid format. at /stages/0/steps/0/action" in errors_on(
               published_changeset
             ).definition

      assert {:error, publish_changeset} = Runbooks.publish(draft, subject)

      assert "Definition value has an invalid format. at /stages/0/steps/0/action" in errors_on(
               publish_changeset
             ).definition
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
    test "strictly imports canonical JSON as an account-scoped draft" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      definition = definition()

      assert {:ok, runbook} =
               Runbooks.import_runbook("Imported maintenance", Jason.encode!(definition), subject)

      assert runbook.account_id == account.id
      assert runbook.title == "Imported maintenance"
      assert runbook.slug == "imported-maintenance"
      assert runbook.status == :draft
      assert runbook.definition == definition

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

  describe "create_published_runbook/2" do
    test "creates a published row only through the named transition" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()

      assert {:ok, runbook} =
               Runbooks.create_published_runbook(runbook_attrs(), subject)

      assert runbook.status == :published
    end

    test "denies an API client that may only draft" do
      {_user, account, owner} = Fixtures.Subjects.owner_subject()
      subject = api_client_subject(account, owner, "draft only")

      assert Runbooks.create_published_runbook(runbook_attrs(), subject) ==
               {:error, :unauthorized}
    end
  end

  describe "create_mcp_draft/4" do
    test "creates and replays exactly once, then rejects changed facts" do
      {_user, account, owner} = Fixtures.Subjects.owner_subject()
      subject = api_client_subject(account, owner, "draft replay")
      operation_id = operation_id()
      fingerprint = String.duplicate("c", 64)
      attrs = runbook_attrs(title: "Agent draft")
      Runbooks.subscribe_account_runbooks(account.id)

      assert {:ok, :created, created} =
               Runbooks.create_mcp_draft(attrs, operation_id, fingerprint, subject)

      assert_receive {:list_changed, :runbook, "runbook.created", created_id}
      assert created_id == created.id

      assert created.id ==
               MCPOperations.resource_id(operation_id, :create_runbook_draft, subject)

      assert {:ok, :replay, replayed} =
               Runbooks.create_mcp_draft(attrs, operation_id, fingerprint, subject)

      assert replayed.id == created.id
      refute_receive {:list_changed, :runbook, _, _}, 50

      assert Runbooks.create_mcp_draft(
               attrs,
               operation_id,
               String.duplicate("d", 64),
               subject
             ) == {:error, :operation_conflict}

      assert Repo.aggregate(Runbooks.Runbook, :count) == 1
      assert Repo.aggregate(MCPOperations.Operation, :count) == 1
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

  describe "save_new_version/3" do
    test "creates an immutable next version and isolates cross-account callers" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      first = create_runbook(subject, slug: "immutable")

      assert {:ok, second} =
               Runbooks.save_new_version(
                 first,
                 %{"title" => "Second", "slug" => "", "description" => "updated"},
                 subject
               )

      assert first.version == 1
      assert second.version == 2
      assert second.slug == "second"
      assert Repo.reload!(first).title != second.title

      {_user, _account, other_subject} = Fixtures.Subjects.owner_subject()

      assert Runbooks.save_new_version(first, %{"title" => "Stolen"}, other_subject) ==
               {:error, :not_found}
    end
  end

  describe "publish/2" do
    test "publishes a visible draft and denies cross-account mutation" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      draft = create_runbook(subject)

      assert {:ok, published} = Runbooks.publish(draft, subject)
      assert published.status == :published

      {_user, _account, other_subject} = Fixtures.Subjects.owner_subject()
      assert Runbooks.publish(published, other_subject) == {:error, :not_found}
    end
  end

  describe "delete_runbook/2" do
    test "soft-deletes the entire visible version family" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      first = create_runbook(subject, slug: "family")
      assert {:ok, second} = Runbooks.save_new_version(first, %{"description" => "v2"}, subject)
      assert {:ok, _deleted} = Runbooks.delete_runbook(first, subject)

      assert Runbooks.fetch_runbook_by_id(first.id, subject) == {:error, :not_found}
      assert Runbooks.fetch_runbook_by_id(second.id, subject) == {:error, :not_found}
    end

    test "does not delete another account's family" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      runbook = create_runbook(subject)
      {_user, _account, other_subject} = Fixtures.Subjects.owner_subject()

      assert Runbooks.delete_runbook(runbook, other_subject) == {:error, :not_found}
      assert {:ok, _fetched} = Runbooks.fetch_runbook_by_id(runbook.id, subject)
    end
  end

  describe "expand/1" do
    test "flattens stage steps in declared order and rejects malformed shapes" do
      first = step("first", "one")
      second = step("second", "two")

      runbook = %Runbooks.Runbook{
        definition: definition([stage("one", [first]), stage("two", [second])])
      }

      assert Runbooks.expand(runbook) == [first, second]
      assert Runbooks.expand(%Runbooks.Runbook{definition: %{}}) == []
    end
  end

  describe "dispatch_runbook/4" do
    test "creates the durable execution and first physical attempt" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      _policy = Fixtures.Policies.create_policy(account_id: account.id)
      runner = trusted_runner(account, subject)
      Runners.subscribe_runner_transport(runner)
      runbook = create_runbook(subject, definition: definition(runner.group)) |> publish(subject)

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
      runbook = create_runbook(subject, definition: definition(runner.group)) |> publish(subject)

      assert Runbooks.dispatch_runbook(runbook, "  ", subject) == {:error, :reason_required}

      {_user, _account, other_subject} = Fixtures.Subjects.owner_subject()

      assert Runbooks.dispatch_runbook(runbook, "cross account", other_subject) ==
               {:error, :not_found}
    end

    test "refuses to run a draft" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      _policy = Fixtures.Policies.create_policy(account_id: account.id)
      runner = trusted_runner(account, subject)
      draft = create_runbook(subject, definition: definition(runner.group))

      assert Runbooks.dispatch_runbook(draft, "inspect the database", subject) ==
               {:error, :not_published}
    end
  end

  describe "resolve_plan/2" do
    test "returns the exact frozen blast radius without dispatching" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      _policy = Fixtures.Policies.create_policy(account_id: account.id)
      runner = trusted_runner(account, subject)
      runbook = create_runbook(subject, definition: definition(runner.group)) |> publish(subject)

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
      runbook = create_runbook(subject, definition: input_definition(runner.group))

      assert {:ok, result} = Runbooks.resolve_plan(runbook, %{"seconds" => 30}, subject)

      assert get_in(result.plan, ["stages", Access.at(0), "items", Access.at(0), "args"]) ==
               %{"seconds" => 30}

      assert {:error, [issue]} =
               Runbooks.resolve_plan(runbook, %{"seconds" => "thirty"}, subject)

      assert issue.path == "/input_values/seconds"
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

  describe "validate_definition/2" do
    test "returns the canonical definition and rejects malformed stages before preflight" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      definition = definition()

      assert {:ok, ^definition} = Runbooks.validate_definition(definition, subject)

      assert {:error, issues} =
               Runbooks.validate_definition(%{"schema_version" => 1, "stages" => []}, subject)

      assert Enum.any?(issues, &(&1.code == "invalid_definition" and &1.path == "/stages"))
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

  describe "validate_model_visible_runbook/2" do
    test "requires a current trusted compatible execution contract" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = trusted_runner(account, subject)
      runbook = create_runbook(subject, definition: definition(runner.group))

      assert Runbooks.validate_model_visible_runbook(runbook, subject) == :ok

      {_user, _account, other_subject} = Fixtures.Subjects.owner_subject()

      assert Runbooks.validate_model_visible_runbook(runbook, other_subject) ==
               {:error, :not_found}
    end

    test "denies model discovery to a principal without view permission" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = trusted_runner(account, subject)
      runbook = create_runbook(subject, definition: definition(runner.group))

      assert Runbooks.validate_model_visible_runbook(
               runbook,
               Subject.for_runner(runner, account)
             ) == {:error, :unauthorized}
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

  defp publish(runbook, subject) do
    assert {:ok, published} = Runbooks.publish(runbook, subject)
    published
  end

  defp delete(runbook, subject) do
    assert {:ok, deleted} = Runbooks.delete_runbook(runbook, subject)
    deleted
  end

  defp runbook_attrs(opts \\ []) do
    title = Keyword.get(opts, :title, "Runbook #{System.unique_integer([:positive])}")

    %{
      "title" => title,
      "slug" => Keyword.get(opts, :slug, "runbook-#{System.unique_integer([:positive])}"),
      "description" => Keyword.get(opts, :description),
      "definition" => Keyword.get(opts, :definition, definition()),
      "status" => Keyword.get(opts, :status)
    }
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
      "targets" => %{"refs" => ["group:" <> group]},
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
        group: Keyword.get(opts, :group, "database")
      )

    assert {:ok, runner} =
             Catalog.observe_state(runner, %{
               "hostname" => runner.hostname,
               "version" => runner.runner_version,
               "labels" => runner.labels,
               "enforce_signatures" => false,
               "packs" => %{"linux-core" => %{"version" => "1.4.2", "hash" => @pack_hash}},
               "actions" => [
                 %{
                   "id" => "linux.uptime",
                   "pack_id" => "linux-core",
                   "title" => "Uptime",
                   "kind" => "exec",
                   "risk" => "low",
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

    assert {:ok, versions} = Catalog.list_all_pack_versions_for_account(subject)

    Enum.each(versions, fn version ->
      if version.trust_state != :trusted do
        assert {:ok, _trusted} = Catalog.trust_pack_version(version.id, subject)
      end
    end)

    runner
  end

  defp api_client_subject(account, owner, name) do
    assert {:ok, _raw, key} = Emisar.ApiKeys.create_key(%{name: name}, owner)
    Subject.for_api_key(key, account)
  end

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
    runbook = create_runbook(owner, definition: definition(runner.group)) |> publish(owner)
    operation_id = operation_id()
    fingerprint = String.duplicate("e", 64)

    assert {:ok, result} =
             Runbooks.dispatch_runbook(
               runbook,
               "inspect fleet",
               subject,
               operation_id: operation_id,
               operation_fingerprint: fingerprint,
               operation_ref: "#{runbook.slug}@#{runbook.version}"
             )

    %{
      account: account,
      execution_id: result.execution_id,
      operation_id: operation_id,
      owner: owner,
      runbook: runbook,
      runner: runner,
      subject: subject
    }
  end

  defp fetch_execution(id) do
    RunbookExecution.Query.by_id(id)
    |> Repo.fetch!(RunbookExecution.Query)
  end

  defp operation_id do
    "op_144NN9NMDZ1T76NARWCKM5A0D6"
  end
end
