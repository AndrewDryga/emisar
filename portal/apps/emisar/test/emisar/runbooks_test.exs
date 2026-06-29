defmodule Emisar.RunbooksTest do
  @moduledoc """
  The runbook context: CRUD + the wave engine. `dispatch_runbook/3` expands
  each step against its own target runner(s) into an execution, releases work
  in waves of five, and `dispatch_next_batch/1` (fired from
  `Runs.mark_finished/2`) advances the waves — halting behind any failed or
  denied run.
  """
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Repo, Runbooks, Runners, Runs}
  alias Emisar.ApiKeys.ApiKey
  alias Emisar.Auth.Subject
  alias Emisar.Fixtures
  alias Emisar.Runbooks.RunbookExecution

  defp account_with_runner do
    {_user, account, subject} = Fixtures.Subjects.owner_subject()
    _ = Fixtures.Policies.create_policy(account_id: account.id)
    runner = Fixtures.Runners.create_runner(account_id: account.id)
    _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
    {account, subject, runner}
  end

  defp published_runbook!(subject, title, steps) do
    {:ok, runbook} =
      Runbooks.create_runbook(
        %{
          "title" => title,
          "name" => title,
          "slug" => title,
          "definition" => %{"steps" => steps}
        },
        subject
      )

    {:ok, runbook} = Runbooks.publish(runbook, subject)
    runbook
  end

  defp draft_runbook!(subject, title) do
    {:ok, runbook} =
      Runbooks.create_runbook(
        %{
          "title" => title,
          "name" => title,
          "slug" => title,
          "definition" => %{"steps" => uptime_steps(1)}
        },
        subject
      )

    runbook
  end

  # Uptime steps, each carrying `selector` as its per-step runner target
  # (omitted when nil — drafts don't need one).
  defp uptime_steps(count, selector \\ nil) do
    for n <- 1..count do
      step = %{"id" => "step#{n}", "action_id" => "linux.uptime", "args" => %{}}
      if selector, do: Map.put(step, "runner_selector", selector), else: step
    end
  end

  defp runner_target(runner), do: %{"runner_id" => [runner.id]}
  defp group_target(group), do: %{"group" => [group]}

  defp save_runbook(subject, steps) do
    title = "rb-#{System.unique_integer([:positive])}"

    Runbooks.create_runbook(
      %{
        "title" => title,
        "name" => title,
        "slug" => title,
        "definition" => %{"steps" => steps}
      },
      subject
    )
  end

  defp draft_with_steps(subject, steps) do
    {:ok, runbook} = save_runbook(subject, steps)
    runbook
  end

  defp finish!(run), do: {:ok, _} = Runs.mark_finished(run, %{"status" => "success"})

  defp execution_runs(account, execution_id),
    do: Runs.list_runs_for_runbook_execution(account.id, execution_id)

  defp step_ids(runs), do: runs |> Enum.map(& &1.runbook_step_id) |> Enum.sort()

  describe "list_runbooks/2" do
    setup do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      %{account: account, subject: subject}
    end

    test "filters by status", %{subject: subject} do
      {_account, _subject, runner} = account_with_runner()
      published = published_runbook!(subject, "live-book", uptime_steps(1, runner_target(runner)))
      draft = draft_runbook!(subject, "wip-book")

      assert {:ok, rows, _} = Runbooks.list_runbooks(subject, filter: [status: ["published"]])
      ids = Enum.map(rows, & &1.id)
      assert published.id in ids
      refute draft.id in ids
    end

    test "returns the caller's own runbooks", %{subject: subject} do
      alpha = draft_runbook!(subject, "alpha-book")
      beta = draft_runbook!(subject, "beta-book")

      assert {:ok, runbooks, _meta} = Runbooks.list_runbooks(subject)
      ids = Enum.map(runbooks, & &1.id)
      assert alpha.id in ids
      assert beta.id in ids
    end

    test "never returns another account's runbooks" do
      {_user, _account_a, subject_a} = Fixtures.Subjects.owner_subject()
      _ = draft_runbook!(subject_a, "mine-book")

      {_user, _account_b, subject_b} = Fixtures.Subjects.owner_subject()
      _ = draft_runbook!(subject_b, "theirs-book")

      {:ok, runbooks, _meta} = Runbooks.list_runbooks(subject_a)
      titles = Enum.map(runbooks, & &1.title)
      assert "mine-book" in titles
      refute "theirs-book" in titles
    end

    test "without view_runbooks is :unauthorized before any DB scope", %{
      account: account,
      subject: subject
    } do
      _ = draft_runbook!(subject, "guarded-book")

      # Every MEMBERSHIP role carries view_runbooks, so the principal that lacks
      # it is the runner subject — its role hits the runbooks authorizer's
      # `_ -> []` clause and the permission gate trips before any row read.
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      runner_subject = Subject.for_runner(runner, account)

      assert {:error, :unauthorized} = Runbooks.list_runbooks(runner_subject)
    end
  end

  describe "fetch_runbook_by_id/2" do
    setup do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      %{account: account, subject: subject}
    end

    test "returns the caller's own runbook", %{subject: subject} do
      runbook = draft_runbook!(subject, "fetchme-book")

      assert {:ok, fetched} = Runbooks.fetch_runbook_by_id(runbook.id, subject)
      assert fetched.id == runbook.id
    end

    test "can't reach across accounts" do
      {_user, _account_a, subject_a} = Fixtures.Subjects.owner_subject()
      {_user, _account_b, subject_b} = Fixtures.Subjects.owner_subject()
      theirs = draft_runbook!(subject_b, "secret-book")

      assert {:error, :not_found} = Runbooks.fetch_runbook_by_id(theirs.id, subject_a)
    end

    test "with a non-uuid id is a clean :not_found", %{subject: subject} do
      assert {:error, :not_found} = Runbooks.fetch_runbook_by_id("not-a-uuid", subject)
    end

    test "excludes a soft-deleted runbook", %{subject: subject} do
      runbook = draft_runbook!(subject, "tombstoned-book")

      # Tombstone the row the way the delete changeset does (a fixture-style
      # direct write — there's no operator delete action). not_deleted/0 then
      # filters it, so the fetch reads :not_found rather than the dead row.
      {:ok, _} =
        runbook |> Runbooks.Runbook.Changeset.delete() |> Repo.update()

      assert {:error, :not_found} = Runbooks.fetch_runbook_by_id(runbook.id, subject)
    end

    test "without view_runbooks is :unauthorized before any DB scope", %{
      account: account,
      subject: subject
    } do
      runbook = draft_runbook!(subject, "guarded-book")

      # Every MEMBERSHIP role (owner/admin/operator/viewer/api_client) carries
      # view_runbooks, so the principal that lacks it is the runner subject — its
      # role hits the runbooks authorizer's `_ -> []` clause. The permission gate
      # trips before for_subject/Repo, so a real owned id still comes back denied.
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      runner_subject = Subject.for_runner(runner, account)

      assert {:error, :unauthorized} =
               Runbooks.fetch_runbook_by_id(runbook.id, runner_subject)
    end
  end

  describe "change_runbook/1" do
    test "builds a valid metadata-form changeset from the editor's text fields" do
      changeset = Runbooks.change_runbook(%{"title" => "Deploy check", "slug" => "deploy-check"})

      assert %Ecto.Changeset{valid?: true} = changeset
      assert Ecto.Changeset.get_change(changeset, :title) == "Deploy check"
      assert Ecto.Changeset.get_change(changeset, :slug) == "deploy-check"
    end

    test "with no attrs is invalid — title is required" do
      changeset = Runbooks.change_runbook()

      refute changeset.valid?
      assert changeset.errors[:title]
    end

    test "surfaces the slug format error for the inline form" do
      changeset = Runbooks.change_runbook(%{"title" => "ok", "slug" => "Not A Valid Slug!"})

      refute changeset.valid?
      assert %{slug: ["has invalid format"]} = errors_on(changeset)
    end
  end

  describe "create_runbook/2" do
    setup do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      %{account: account, subject: subject}
    end

    test "persists a draft and writes a runbook.created audit row + list broadcast", %{
      account: account,
      subject: subject
    } do
      # The runbook list LV subscribes to this topic to live-refresh; the create
      # must publish `{:list_changed, :runbook, "runbook.created", id}` after commit.
      Runbooks.subscribe_account_runbooks(account.id)

      assert {:ok, runbook} =
               Runbooks.create_runbook(
                 %{
                   "title" => "audited-book",
                   "name" => "audited-book",
                   "slug" => "audited-book",
                   "definition" => %{"steps" => uptime_steps(1)}
                 },
                 subject
               )

      assert runbook.status == :draft
      assert runbook.version == 1

      assert_receive {:list_changed, :runbook, "runbook.created", broadcast_id}
      assert broadcast_id == runbook.id

      # The Multi writes the audit row in the same transaction as the insert.
      {:ok, events, _} = Emisar.Audit.list_events(subject, page: [limit: 20])
      created = Enum.find(events, &(&1.event_type == "runbook.created"))
      assert created.subject_id == runbook.id
    end

    test "rejects a slug that doesn't match the URL-safe format", %{subject: subject} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Runbooks.create_runbook(
                 %{
                   "title" => "Bad Slug Book",
                   "name" => "bad-slug",
                   "slug" => "Not A Valid Slug!",
                   "definition" => %{"steps" => uptime_steps(1)}
                 },
                 subject
               )

      assert %{slug: ["has invalid format"]} = errors_on(changeset)
    end

    test "an operator (view-only, no manage_runbooks) cannot create a runbook", %{
      account: account
    } do
      operator =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :operator)

      # Operators hold view_runbooks but not manage_runbooks — create_runbook gates
      # on manage, so they're refused (an operator can RUN a runbook, not edit one).
      assert {:error, :unauthorized} = save_runbook(operator, uptime_steps(1))
    end

    test "an owner of another account can't create against this account (cross-account)" do
      {_user_a, account_a, _subject_a} = Fixtures.Subjects.owner_subject()
      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      # create_runbook stamps the row to subject.account, so account B's owner
      # creates only in B — A gets no row from B's call.
      assert {:ok, runbook} =
               Runbooks.create_runbook(
                 %{
                   "title" => "b-book",
                   "name" => "b-book",
                   "slug" => "b-book-#{System.unique_integer([:positive])}",
                   "definition" => %{"steps" => uptime_steps(1)}
                 },
                 subject_b
               )

      refute runbook.account_id == account_a.id
    end

    test "a duplicate (account, slug, version) is rejected by the unique constraint", %{
      subject: subject
    } do
      attrs = %{
        "title" => "dup-slug-book",
        "name" => "dup-slug-book",
        "slug" => "dup-slug-book",
        "definition" => %{"steps" => uptime_steps(1)}
      }

      # create_runbook always stamps version 1, so a second create with the same
      # slug collides on the (account_id, slug, version) unique index — mapped back
      # to a changeset error, not a read-before-write check (IL: the DB index is
      # the source of truth).
      assert {:ok, _} = Runbooks.create_runbook(attrs, subject)
      assert {:error, %Ecto.Changeset{} = changeset} = Runbooks.create_runbook(attrs, subject)
      # unique_constraint([:account_id, :slug, :version]) reports against its
      # first field, so the violation surfaces on :account_id.
      assert "has already been taken" in errors_on(changeset).account_id
    end

    test "saving a runbook with too many steps is rejected", %{subject: subject} do
      steps =
        for n <- 1..101, do: %{"id" => "step#{n}", "action_id" => "linux.uptime", "args" => %{}}

      assert {:error, %Ecto.Changeset{} = changeset} = save_runbook(subject, steps)
      assert "has too many steps (max 100)" in errors_on(changeset).definition
    end

    test "saving an oversized definition is rejected", %{subject: subject} do
      blob = String.duplicate("x", 70_000)
      steps = [%{"id" => "s1", "action_id" => "linux.uptime", "args" => %{"blob" => blob}}]

      assert {:error, %Ecto.Changeset{} = changeset} = save_runbook(subject, steps)
      assert "is too large (max 65536 bytes)" in errors_on(changeset).definition
    end

    test "saving a step that targets too many runners is rejected", %{subject: subject} do
      steps = [
        %{
          "id" => "s1",
          "action_id" => "linux.uptime",
          "args" => %{},
          "runner_selector" => %{"runner_id" => Enum.map(1..51, &"r#{&1}")}
        }
      ]

      assert {:error, %Ecto.Changeset{} = changeset} = save_runbook(subject, steps)

      assert "a step targets too many runners or groups (max 50)" in errors_on(changeset).definition
    end

    test "args count toward the serialized definition byte cap", %{subject: subject} do
      # No single arg/step is oversized and the step count (10) is well under 100 —
      # it's the args, in aggregate, that push the serialized definition over 65536
      # bytes (validate_definition_bounds encodes the WHOLE definition, args included).
      filler = String.duplicate("x", 800)

      steps =
        for n <- 1..10 do
          args = Map.new(1..10, fn k -> {"arg_#{n}_#{k}", filler} end)
          %{"id" => "step#{n}", "action_id" => "linux.uptime", "args" => args}
        end

      assert {:error, %Ecto.Changeset{} = changeset} = save_runbook(subject, steps)
      assert "is too large (max 65536 bytes)" in errors_on(changeset).definition
    end

    test "a step with exactly 50 targets is accepted (the selector boundary)", %{subject: subject} do
      # @max_selector_values is 50 — exactly 50 saves (the 51-rejected half is the
      # "too many runners" test above; this proves the accepted boundary).
      step = %{
        "id" => "s1",
        "action_id" => "linux.uptime",
        "args" => %{},
        "runner_selector" => %{"runner_id" => Enum.map(1..50, &"r#{&1}")}
      }

      assert {:ok, runbook} = save_runbook(subject, [step])
      assert runbook.status == :draft
    end
  end

  describe "subscribe_account_runbooks/1" do
    test "the subscriber receives the account's runbook-list broadcasts" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()

      assert :ok = Runbooks.subscribe_account_runbooks(account.id)

      # A create publishes on the topic the subscriber just joined.
      {:ok, runbook} =
        Runbooks.create_runbook(
          %{
            "title" => "sub-book",
            "name" => "sub-book",
            "slug" => "sub-book",
            "definition" => %{"steps" => uptime_steps(1)}
          },
          subject
        )

      assert_receive {:list_changed, :runbook, "runbook.created", broadcast_id}
      assert broadcast_id == runbook.id
    end

    test "a subscriber to account A does not receive account B's broadcasts" do
      {_user_a, account_a, _subject_a} = Fixtures.Subjects.owner_subject()
      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      assert :ok = Runbooks.subscribe_account_runbooks(account_a.id)

      # The create happens in B's account — A's subscriber must hear nothing.
      {:ok, _} =
        Runbooks.create_runbook(
          %{
            "title" => "b-only-book",
            "name" => "b-only-book",
            "slug" => "b-only-book",
            "definition" => %{"steps" => uptime_steps(1)}
          },
          subject_b
        )

      refute_receive {:list_changed, :runbook, _event, _id}
    end
  end

  describe "save_new_version/3" do
    setup do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      %{account: account, subject: subject}
    end

    test "bumps the version, persists the new attrs, and leaves the old row intact", %{
      subject: subject
    } do
      v1 = draft_runbook!(subject, "ver-book")

      assert {:ok, v2} = Runbooks.save_new_version(v1, %{"title" => "ver-book take two"}, subject)

      assert v2.version == v1.version + 1
      assert v2.title == "ver-book take two"
      assert v2.id != v1.id
      # The prior version is its own row and stays fetchable.
      assert {:ok, _} = Runbooks.fetch_runbook_by_id(v1.id, subject)
    end

    test "a viewer (no manage permission) is refused", %{account: account, subject: subject} do
      v1 = draft_runbook!(subject, "guard-book")
      viewer = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :viewer)

      assert {:error, :unauthorized} =
               Runbooks.save_new_version(v1, %{"title" => "nope"}, viewer)
    end

    test "an owner of another account can't version this runbook" do
      {_user, _account_a, subject_a} = Fixtures.Subjects.owner_subject()
      v1 = draft_runbook!(subject_a, "owned-book")

      {_user, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      assert {:error, :not_found} =
               Runbooks.save_new_version(v1, %{"title" => "hijack"}, subject_b)
    end

    test "a new version re-checks the definition step cap", %{subject: subject} do
      v1 = draft_runbook!(subject, "bounds-book")

      # new_version runs the SAME changeset/1 as create, so the >100-step cap is
      # re-enforced on a version that pushes the definition over it (not just at
      # first create) — a save that grows the runbook can't slip past the bound.
      steps =
        for n <- 1..101, do: %{"id" => "step#{n}", "action_id" => "linux.uptime", "args" => %{}}

      assert {:error, %Ecto.Changeset{} = changeset} =
               Runbooks.save_new_version(v1, %{"definition" => %{"steps" => steps}}, subject)

      assert "has too many steps (max 100)" in errors_on(changeset).definition
    end

    test "a new version re-runs the same metadata validation as create", %{subject: subject} do
      v1 = draft_runbook!(subject, "meta-book")

      # A bad slug fails the shared changeset/1 format validation on save_new_version
      # exactly as it does on create — the editor binds it inline; the context
      # rejects it rather than persisting a malformed version.
      assert {:error, %Ecto.Changeset{} = changeset} =
               Runbooks.save_new_version(v1, %{"slug" => "Not A Slug!"}, subject)

      assert %{slug: ["has invalid format"]} = errors_on(changeset)
    end

    test "a new version writes a runbook.updated audit row carrying from/to version", %{
      account: account,
      subject: subject
    } do
      v1 = draft_runbook!(subject, "audited-version-book")

      # The list LV live-refreshes off this topic; saving a version must broadcast
      # runbook.updated after commit.
      Runbooks.subscribe_account_runbooks(account.id)

      assert {:ok, v2} = Runbooks.save_new_version(v1, %{"title" => "v2 title"}, subject)
      assert_receive {:list_changed, :runbook, "runbook.updated", broadcast_id}
      assert broadcast_id == v2.id

      # The Multi writes the audit row in the same transaction as the version
      # insert; its payload carries the version bump (from_version → to_version)
      # so the audit trail shows which version the save produced.
      {:ok, events, _} = Emisar.Audit.list_events(subject, page: [limit: 20])
      updated = Enum.find(events, &(&1.event_type == "runbook.updated"))
      assert updated.subject_id == v2.id
      assert updated.payload["from_version"] == v1.version
      assert updated.payload["to_version"] == v2.version
    end
  end

  describe "publish/2" do
    setup do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      %{account: account, subject: subject}
    end

    test "publishing valid steps succeeds and flips the status to published", %{subject: subject} do
      draft =
        draft_with_steps(subject, [
          %{
            "id" => "s1",
            "action_id" => "linux.uptime",
            "args" => %{},
            "runner_selector" => %{"group" => ["prod"]}
          }
        ])

      assert {:ok, runbook} = Runbooks.publish(draft, subject)
      assert runbook.status == :published
    end

    test "publishing writes a runbook.published audit row + list broadcast", %{
      account: account,
      subject: subject
    } do
      draft =
        draft_with_steps(subject, [
          %{
            "id" => "s1",
            "action_id" => "linux.uptime",
            "args" => %{},
            "runner_selector" => %{"group" => ["prod"]}
          }
        ])

      Runbooks.subscribe_account_runbooks(account.id)

      assert {:ok, runbook} = Runbooks.publish(draft, subject)
      assert_receive {:list_changed, :runbook, "runbook.published", broadcast_id}
      assert broadcast_id == runbook.id

      {:ok, events, _} = Emisar.Audit.list_events(subject, page: [limit: 20])
      published = Enum.find(events, &(&1.event_type == "runbook.published"))
      assert published.subject_id == runbook.id
    end

    test "a draft saves with an incomplete (blank-action) step — WIP is allowed", %{
      subject: subject
    } do
      draft = draft_with_steps(subject, [%{"id" => "s1", "action_id" => "", "args" => %{}}])
      assert draft.status == :draft
    end

    test "publishing a blank-action step is rejected", %{subject: subject} do
      draft = draft_with_steps(subject, [%{"id" => "s1", "action_id" => "", "args" => %{}}])

      assert {:error, %Ecto.Changeset{} = changeset} = Runbooks.publish(draft, subject)
      assert "every step needs an action before publishing" in errors_on(changeset).definition
    end

    test "publishing an empty runbook is rejected", %{subject: subject} do
      draft = draft_with_steps(subject, [])

      assert {:error, %Ecto.Changeset{} = changeset} = Runbooks.publish(draft, subject)
      assert "add at least one step before publishing" in errors_on(changeset).definition
    end

    test "publishing a step with no runner target is rejected", %{subject: subject} do
      draft =
        draft_with_steps(subject, [%{"id" => "s1", "action_id" => "linux.uptime", "args" => %{}}])

      assert {:error, %Ecto.Changeset{} = changeset} = Runbooks.publish(draft, subject)

      assert "every step needs a runner or group target before publishing" in errors_on(changeset).definition
    end

    test "publishing a step with a blank id is rejected", %{subject: subject} do
      draft =
        draft_with_steps(subject, [
          %{
            "id" => "  ",
            "action_id" => "linux.uptime",
            "args" => %{},
            "runner_selector" => %{"group" => ["prod"]}
          }
        ])

      assert {:error, %Ecto.Changeset{} = changeset} = Runbooks.publish(draft, subject)

      assert "every step needs an ID of 1–80 characters before publishing" in errors_on(changeset).definition
    end

    test "publishing duplicate step ids is rejected", %{subject: subject} do
      target = %{"group" => ["prod"]}

      draft =
        draft_with_steps(subject, [
          %{
            "id" => "dup",
            "action_id" => "linux.uptime",
            "args" => %{},
            "runner_selector" => target
          },
          %{
            "id" => "dup",
            "action_id" => "linux.uptime",
            "args" => %{},
            "runner_selector" => target
          }
        ])

      assert {:error, %Ecto.Changeset{} = changeset} = Runbooks.publish(draft, subject)
      assert "every step needs a unique ID before publishing" in errors_on(changeset).definition
    end

    test "a non-manager (viewer or operator) cannot publish", %{account: account, subject: owner} do
      draft =
        draft_with_steps(owner, [
          %{
            "id" => "s1",
            "action_id" => "linux.uptime",
            "args" => %{},
            "runner_selector" => %{"group" => ["prod"]}
          }
        ])

      # Publish gates on manage_runbooks (owner/admin only). A viewer and an
      # operator both hold only view_runbooks, so the authz gate refuses both
      # before the publishable-steps changeset even runs.
      viewer = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :viewer)

      operator =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :operator)

      assert {:error, :unauthorized} = Runbooks.publish(draft, viewer)
      assert {:error, :unauthorized} = Runbooks.publish(draft, operator)
    end

    test "cross-account: account B cannot publish account A's runbook → :not_found" do
      {_user, _account, owner} = Fixtures.Subjects.owner_subject()
      draft = draft_runbook!(owner, "a-book")

      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()
      # B is an owner (so it clears the manage_runbooks gate), but for_subject
      # scopes the locked fetch to account B — A's draft isn't visible, so the
      # publish never reaches the changeset: :not_found, not :unauthorized.
      assert {:error, :not_found} = Runbooks.publish(draft, subject_b)
    end
  end

  describe "expand/1" do
    test "returns the runbook's ordered step descriptors" do
      steps = [
        %{"id" => "step1", "action_id" => "linux.uptime", "args" => %{}},
        %{"id" => "step2", "action_id" => "linux.uptime", "args" => %{}}
      ]

      runbook = %Runbooks.Runbook{definition: %{"steps" => steps}}

      assert Runbooks.expand(runbook) == steps
    end

    test "a runbook with no steps key expands to the empty list" do
      assert Runbooks.expand(%Runbooks.Runbook{definition: %{}}) == []
    end

    test "a nil definition expands to the empty list (the catch-all clause)" do
      assert Runbooks.expand(%Runbooks.Runbook{definition: nil}) == []
    end
  end

  describe "dispatch_runbook/3" do
    setup do
      {account, subject, runner} = account_with_runner()
      %{account: account, subject: subject, runner: runner}
    end

    test "dispatches a small runbook in one wave, stamped with the execution", %{
      subject: subject,
      runner: runner
    } do
      runbook =
        published_runbook!(subject, "deploy-check", uptime_steps(3, runner_target(runner)))

      assert {:ok, %{execution_id: execution_id, total: 3, runs: runs, errors: []}} =
               Runbooks.dispatch_runbook(runbook, "release 42", subject)

      assert step_ids(runs) == ["step1", "step2", "step3"]

      for run <- runs do
        assert run.runbook_id == runbook.id
        assert run.runbook_execution_id == execution_id
        assert run.runner_id == runner.id
      end

      # The visible reason is prefixed per step; the raw operator reason lives on
      # the durable execution row for continuation re-prefixing.
      step1 = Enum.find(runs, &(&1.runbook_step_id == "step1"))
      assert step1.reason == "runbook: deploy-check • step 1/3 — release 42"
    end

    test "returns the full plan keyed to match the runs it creates", %{
      subject: subject,
      runner: runner
    } do
      runbook =
        published_runbook!(subject, "plan-shape", uptime_steps(3, runner_target(runner)))

      assert {:ok, %{plan: plan, runs: runs}} =
               Runbooks.dispatch_runbook(runbook, "release", subject)

      # One plan row per (step, runner) the execution will run — the dispatch
      # UI renders these up front, then flips each to its live run.
      assert Enum.map(plan, & &1.step_id) == ["step1", "step2", "step3"]
      assert Enum.all?(plan, &(&1.runner_id == runner.id))

      # Every created run matches a plan row exactly by (step_id, runner_id) —
      # the key the LiveView flips a placeholder in place on.
      plan_keys = MapSet.new(plan, &{&1.step_id, &1.runner_id})
      assert Enum.all?(runs, &MapSet.member?(plan_keys, {&1.runbook_step_id, &1.runner_id}))
    end

    test "a group target fans every step out across the group's active runners", %{
      account: account,
      subject: subject,
      runner: runner
    } do
      peer = Fixtures.Runners.create_runner(account_id: account.id, group: runner.group)
      _ = Fixtures.Catalog.create_action(runner: peer, action_id: "linux.uptime", risk: "low")

      # Noise the resolver must skip: a disabled runner in the group, an
      # active runner in another group, and another account's runner in a
      # same-named group.
      disabled =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          group: runner.group,
          connected?: false
        )

      {:ok, _} = Runners.disable_runner(disabled, subject)
      _ = Fixtures.Runners.create_runner(account_id: account.id, group: "elsewhere")
      _ = Fixtures.Runners.create_runner(group: runner.group)

      runbook =
        published_runbook!(subject, "fleet-sweep", uptime_steps(2, group_target(runner.group)))

      assert {:ok, %{total: 4, runs: runs, errors: []}} =
               Runbooks.dispatch_runbook(runbook, "audit", subject)

      assert length(runs) == 4

      dispatched_runner_ids = runs |> Enum.map(& &1.runner_id) |> Enum.uniq() |> Enum.sort()
      assert dispatched_runner_ids == Enum.sort([runner.id, peer.id])
    end

    test "a step whose group has no active runners refuses dispatch", %{subject: subject} do
      runbook = published_runbook!(subject, "ghost-town", uptime_steps(1, group_target("ghost")))

      assert {:error, {:step_no_runners, 1}} =
               Runbooks.dispatch_runbook(runbook, "audit", subject)
    end

    test "a policy denial writes the denied row into the execution" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()

      _ =
        Fixtures.Policies.create_policy(
          account_id: account.id,
          rules: %{
            "schema_version" => 2,
            "defaults" => %{
              "low" => "deny",
              "medium" => "deny",
              "high" => "deny",
              "critical" => "deny"
            },
            "overrides" => []
          }
        )

      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      runbook = published_runbook!(subject, "denied-book", uptime_steps(1, runner_target(runner)))

      assert {:ok, %{execution_id: execution_id, total: 1, runs: [], errors: []}} =
               Runbooks.dispatch_runbook(runbook, "try", subject)

      assert [denied] = execution_runs(account, execution_id)
      assert denied.status == :denied
      assert denied.runbook_step_id == "step1"
    end

    test "a draft with colliding step ids refuses dispatch instead of silently skipping work", %{
      subject: subject,
      runner: runner
    } do
      target = runner_target(runner)

      runbook =
        draft_with_steps(subject, [
          %{
            "id" => "dup",
            "action_id" => "linux.uptime",
            "args" => %{},
            "runner_selector" => target
          },
          %{
            "id" => "dup",
            "action_id" => "linux.uptime",
            "args" => %{},
            "runner_selector" => target
          }
        ])

      assert {:error, :duplicate_step_ids} = Runbooks.dispatch_runbook(runbook, "go", subject)
      assert {:error, :duplicate_step_ids} = Runbooks.resolve_plan(runbook, subject)
      # No run row was created — the collision is caught before any dispatch.
      assert {:ok, [], _meta} = Runs.list_runs(subject)
    end

    test "refuses a runbook whose resolved fan-out exceeds the cap", %{subject: subject} do
      # (resolve_plan half)
      # 21 steps × 50 runner targets = 1050 resolved runs, over the 1000 cap. The
      # ids needn't exist — the cap is checked while resolving, before any dispatch.
      steps =
        for n <- 1..21 do
          %{
            "id" => "step#{n}",
            "action_id" => "linux.uptime",
            "args" => %{},
            "runner_selector" => %{"runner_id" => Enum.map(1..50, &"r#{n}_#{&1}")}
          }
        end

      runbook = draft_with_steps(subject, steps)

      assert {:error, {:fan_out_too_large, 1000}} =
               Runbooks.dispatch_runbook(runbook, "go", subject)

      assert {:error, {:fan_out_too_large, 1000}} = Runbooks.resolve_plan(runbook, subject)
      assert {:ok, [], _meta} = Runs.list_runs(subject)
    end

    test "a step whose policy requires approval queues a pending-approval run, not a hard error" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()

      # The same per-step policy/approval gate a normal run hits: require_approval
      # on every risk → the dispatched run parks for a human instead of erroring.
      _ =
        Fixtures.Policies.create_policy(
          account_id: account.id,
          rules: %{
            "schema_version" => 2,
            "defaults" => %{
              "low" => "require_approval",
              "medium" => "require_approval",
              "high" => "require_approval",
              "critical" => "require_approval"
            },
            "overrides" => []
          }
        )

      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      runbook = published_runbook!(subject, "gated-book", uptime_steps(1, runner_target(runner)))

      assert {:ok, %{execution_id: execution_id, total: 1, runs: [run], errors: []}} =
               Runbooks.dispatch_runbook(runbook, "needs sign-off", subject)

      # The run exists and waits on an operator (per-step approval honored) — it is
      # a real run row in the execution, not a dispatch failure.
      assert run.status == :pending_approval
      assert run.runbook_step_id == "step1"
      assert [pending] = execution_runs(account, execution_id)
      assert pending.status == :pending_approval
    end

    test "an api_client without a membership is refused with :membership_required" do
      {_user, account, owner} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      runbook = published_runbook!(owner, "keyless-book", uptime_steps(1, runner_target(runner)))

      # An API-key subject in the runbook's account holding dispatch_run but minted
      # without a creator membership (membership_id: nil). The continuation re-runs
      # this gate every wave, so a user-less dispatch with no membership is refused
      # up front rather than running unscoped.
      keyless =
        Subject.for_api_key(%ApiKey{id: Repo.generate_id(), account_id: account.id}, account)

      assert {:error, :membership_required} =
               Runbooks.dispatch_runbook(runbook, "go", keyless)

      # Nothing dispatched — the gate trips before any run row (or execution) exists.
      assert {:ok, [], _meta} = Runs.list_runs(owner)
    end

    test "dispatching to an offline in-account runner queues the run rather than erroring" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      _ = Fixtures.Policies.create_policy(account_id: account.id)
      # An offline runner that still advertises the action. A runner-id selector
      # passes it through (a group selector would skip offline members), and the
      # dispatch broadcasts the run_action envelope regardless of presence — so the
      # run is CREATED (queued in :sent/:pending), not refused. It executes once the
      # runner reconnects; offline is a heads-up, not a hard dispatch failure.
      offline = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      _ = Fixtures.Catalog.create_action(runner: offline, action_id: "linux.uptime", risk: "low")

      runbook =
        published_runbook!(subject, "queued-book", uptime_steps(1, runner_target(offline)))

      assert {:ok, %{execution_id: execution_id, total: 1, runs: [run], errors: []}} =
               Runbooks.dispatch_runbook(runbook, "go", subject)

      assert run.runner_id == offline.id
      assert run.status in [:pending, :sent]
      assert [queued] = execution_runs(account, execution_id)
      assert queued.id == run.id
    end

    test "a single-step runbook that can't dispatch at all returns the bare reason" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      _ = Fixtures.Policies.create_policy(account_id: account.id)
      # A runner in the account that NEVER advertised the action → its sole slot
      # fails to dispatch (:action_not_found). With no run row created and nothing
      # else in the wave, the whole start failed, so dispatch hands back the bare
      # reason — not an execution map with a per-row error (that shape is only
      # useful when SOME rows dispatched and others didn't, the partial-wave case).
      mute = Fixtures.Runners.create_runner(account_id: account.id)
      runbook = published_runbook!(subject, "doomed-book", uptime_steps(1, runner_target(mute)))

      assert {:error, :action_not_found} = Runbooks.dispatch_runbook(runbook, "go", subject)

      # Nothing dispatched — no run row survives the failed start.
      assert {:ok, [], _meta} = Runs.list_runs(subject)
    end

    test "requires the reason to be a binary (function-head guard)", %{
      subject: subject,
      runner: runner
    } do
      runbook =
        published_runbook!(subject, "guarded-reason", uptime_steps(1, runner_target(runner)))

      # `reason` is a required positional with a `when is_binary(reason)` head guard
      # — a non-binary reason has no matching clause, so the call raises rather than
      # silently dispatching a run whose audit reason is a nil/term. (Bound through
      # a var so the compiler's type checker doesn't flag the deliberate mismatch.)
      bad_reason = Enum.random([nil, 42])

      assert_raise FunctionClauseError, fn ->
        Runbooks.dispatch_runbook(runbook, bad_reason, subject)
      end
    end

    test "reordering steps changes which step fans out into the first wave", %{
      account: account,
      subject: subject,
      runner: runner
    } do
      # 3 runners in one group + a 2-step runbook = 6 work-list items across 2
      # waves. resolve_work_list is step-MAJOR: whichever step is first fans across
      # all its runners before the second claims a wave slot. So the first 3 plan
      # rows all carry step 1's id — reorder the steps and a different id leads.
      for _ <- 1..2 do
        peer = Fixtures.Runners.create_runner(account_id: account.id, group: runner.group)
        Fixtures.Catalog.create_action(runner: peer, action_id: "linux.uptime", risk: "low")
      end

      target = group_target(runner.group)

      step_a = %{
        "id" => "alpha",
        "action_id" => "linux.uptime",
        "args" => %{},
        "runner_selector" => target
      }

      step_b = %{
        "id" => "bravo",
        "action_id" => "linux.uptime",
        "args" => %{},
        "runner_selector" => target
      }

      ab = published_runbook!(subject, "order-ab", [step_a, step_b])
      {:ok, %{plan: plan_ab}} = Runbooks.resolve_plan(ab, subject)
      assert plan_ab |> Enum.take(3) |> Enum.map(& &1.step_id) == ["alpha", "alpha", "alpha"]

      # Same steps, swapped — now bravo leads the first wave.
      ba = published_runbook!(subject, "order-ba", [step_b, step_a])
      {:ok, %{plan: plan_ba}} = Runbooks.resolve_plan(ba, subject)
      assert plan_ba |> Enum.take(3) |> Enum.map(& &1.step_id) == ["bravo", "bravo", "bravo"]
    end

    test "duplicate auto-derived step ids pass a draft save but are refused at dispatch", %{
      subject: subject,
      runner: runner
    } do
      target = runner_target(runner)

      # Two steps share an id (as the editor's auto-derive could produce for two
      # steps on the same action). A DRAFT save allows it — completeness is a
      # publish concern — but dispatch refuses loudly so the {step_id, runner}
      # unique index can't silently collapse the two distinct steps into one.
      runbook =
        draft_with_steps(subject, [
          %{
            "id" => "linux_uptime",
            "action_id" => "linux.uptime",
            "args" => %{},
            "runner_selector" => target
          },
          %{
            "id" => "linux_uptime",
            "action_id" => "linux.uptime",
            "args" => %{},
            "runner_selector" => target
          }
        ])

      assert runbook.status == :draft
      assert {:error, :duplicate_step_ids} = Runbooks.dispatch_runbook(runbook, "go", subject)
    end

    test "denies a subject without dispatch permission → :unauthorized", %{
      account: account,
      subject: subject,
      runner: runner
    } do
      runbook = published_runbook!(subject, "rb", uptime_steps(1, group_target(runner.group)))

      # Dispatch gates on dispatch_run; a viewer holds only view_runbooks, so the
      # permission check refuses before a single run is created.
      viewer = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :viewer)
      assert {:error, :unauthorized} = Runbooks.dispatch_runbook(runbook, "release", viewer)
    end

    test "refuses a runbook from another account → :not_found", %{
      subject: subject,
      runner: runner
    } do
      runbook = published_runbook!(subject, "rb", uptime_steps(1, group_target(runner.group)))

      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()
      # :not_found, not :unauthorized — Subject.ensure_in_account hides A's runbook
      # from B (same blind as resolve_plan); B can't tell it exists, and no run is
      # created in either account.
      assert {:error, :not_found} = Runbooks.dispatch_runbook(runbook, "release", subject_b)
    end

    test "the (execution, step, runner) unique index rejects a duplicate slot claim", %{
      subject: subject,
      runner: runner
    } do
      runbook = published_runbook!(subject, "race-book", uptime_steps(1, runner_target(runner)))

      assert {:ok, %{execution_id: execution_id, runs: [run]}} =
               Runbooks.dispatch_runbook(runbook, "go", subject)

      assert {:error, changeset} =
               Runs.create_run(%{
                 account_id: run.account_id,
                 runner_id: runner.id,
                 action_id: "linux.uptime",
                 reason: "racer",
                 source: "runbook",
                 runbook_id: runbook.id,
                 runbook_step_id: run.runbook_step_id,
                 runbook_execution_id: execution_id
               })

      assert {_msg, opts} = changeset.errors[:runbook_execution_id]
      assert opts[:constraint_name] == "action_runs_execution_step_runner_index"
    end
  end

  describe "resolve_plan/2 (blast radius, no dispatch)" do
    setup do
      {account, subject, runner} = account_with_runner()
      %{account: account, subject: subject, runner: runner}
    end

    test "returns the work-list total + wave count without creating any runs", %{
      account: account,
      subject: subject,
      runner: runner
    } do
      # Three active runners in the group → a 2-step runbook fans out to 6 runs;
      # at @batch_size 5 that's 2 waves — exercises the ceil, not just 1 wave.
      for _ <- 1..2 do
        peer = Fixtures.Runners.create_runner(account_id: account.id, group: runner.group)
        Fixtures.Catalog.create_action(runner: peer, action_id: "linux.uptime", risk: "low")
      end

      runbook =
        published_runbook!(subject, "fleet-sweep", uptime_steps(2, group_target(runner.group)))

      assert {:ok, %{total: 6, waves: 2, plan: plan}} = Runbooks.resolve_plan(runbook, subject)
      assert length(plan) == 6

      # Read-only: resolving the blast radius dispatches nothing.
      assert {:ok, [], _} = Emisar.Runs.list_recent_runs(subject, limit: 10)
    end

    test "reports the step whose group has no active runners (the pre-dispatch warning)", %{
      subject: subject
    } do
      runbook = published_runbook!(subject, "ghost-town", uptime_steps(1, group_target("ghost")))

      assert {:error, {:step_no_runners, 1}} = Runbooks.resolve_plan(runbook, subject)
    end

    test "denies a subject without dispatch permission", %{
      account: account,
      subject: subject,
      runner: runner
    } do
      runbook = published_runbook!(subject, "rb", uptime_steps(1, group_target(runner.group)))

      viewer = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :viewer)
      assert {:error, :unauthorized} = Runbooks.resolve_plan(runbook, viewer)
    end

    test "refuses a runbook from another account", %{subject: subject, runner: runner} do
      runbook = published_runbook!(subject, "rb", uptime_steps(1, group_target(runner.group)))

      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()
      # Cross-account is :not_found, not :unauthorized — account B can't tell A's
      # runbook exists (same as dispatch_runbook's `Subject.ensure_in_account`).
      assert {:error, :not_found} = Runbooks.resolve_plan(runbook, subject_b)
    end

    test "an operator (dispatch_run but not manage_runbooks) can resolve the plan", %{
      account: account,
      subject: owner,
      runner: runner
    } do
      runbook = published_runbook!(owner, "operable", uptime_steps(1, runner_target(runner)))

      # resolve_plan gates on dispatch_run, NOT manage_runbooks — so an operator
      # who can't EDIT a runbook can still preflight (and run) it. The run screen
      # depends on this split: it's the same gate the dispatch path uses.
      operator =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :operator)

      refute Runbooks.subject_can_manage_runbooks?(operator)

      assert {:ok, %{total: 1, waves: 1, plan: [_]}} = Runbooks.resolve_plan(runbook, operator)
    end
  end

  describe "dispatch_next_batch/1" do
    setup do
      {account, subject, runner} = account_with_runner()
      %{account: account, subject: subject, runner: runner}
    end

    test "a non-runbook run is a no-op (the catch-all clause)", %{
      subject: subject,
      runner: runner
    } do
      # A plain run carries no runbook_id/execution_id, so the second clause's
      # guard doesn't match the struct head — dispatch_next_batch must no-op
      # rather than advancing a wave that doesn't exist.
      assert {:ok, _status, run} =
               Runs.dispatch_run(
                 %{runner_id: runner.id, action_id: "linux.uptime", reason: "solo"},
                 subject
               )

      assert is_nil(run.runbook_id)
      assert Runbooks.dispatch_next_batch(run) == :noop
    end

    test "releases the next wave only when the whole wave finishes", %{
      account: account,
      subject: subject,
      runner: runner
    } do
      runbook = published_runbook!(subject, "seven-steps", uptime_steps(7, runner_target(runner)))

      assert {:ok, %{execution_id: execution_id, total: 7, runs: wave1}} =
               Runbooks.dispatch_runbook(runbook, "go", subject)

      assert step_ids(wave1) == ["step1", "step2", "step3", "step4", "step5"]

      # Finishing part of the wave doesn't release the next one.
      wave1 |> Enum.take(4) |> Enum.each(&finish!/1)
      assert length(execution_runs(account, execution_id)) == 5

      # The last finisher does.
      wave1 |> List.last() |> finish!()

      runs = execution_runs(account, execution_id)
      assert step_ids(runs) == ["step1", "step2", "step3", "step4", "step5", "step6", "step7"]
    end

    test "a failed run halts the waves behind it", %{
      account: account,
      subject: subject,
      runner: runner
    } do
      runbook =
        published_runbook!(subject, "halting-book", uptime_steps(7, runner_target(runner)))

      assert {:ok, %{execution_id: execution_id, runs: [first | rest]}} =
               Runbooks.dispatch_runbook(runbook, "go", subject)

      {:ok, _} = Runs.mark_finished(first, %{"status" => "failed", "exit_code" => 1})
      Enum.each(rest, &finish!/1)

      # Steps 6-7 never dispatch; the in-flight wave finished naturally.
      assert length(execution_runs(account, execution_id)) == 5

      # Halting is engine behavior, not a dispatch failure — no audit noise.
      {:ok, events, _} = Emisar.Audit.list_events(subject, page: [limit: 50])
      refute Enum.any?(events, &(&1.event_type == "runbook.step_dispatch_failed"))
    end

    test "a partial first-wave dispatch failure carries the (step, runner) it belongs to", %{
      account: account,
      subject: subject,
      runner: runner
    } do
      # A second runner that never advertised the action → dispatching its slot
      # fails while the first runner's succeeds (a partial wave failure).
      other = Fixtures.Runners.create_runner(account_id: account.id)

      steps = [
        %{
          "id" => "ok",
          "action_id" => "linux.uptime",
          "args" => %{},
          "runner_selector" => runner_target(runner)
        },
        %{
          "id" => "bad",
          "action_id" => "linux.uptime",
          "args" => %{},
          "runner_selector" => runner_target(other)
        }
      ]

      runbook = published_runbook!(subject, "partial-book", steps)

      assert {:ok, %{runs: [_run], errors: [error]}} =
               Runbooks.dispatch_runbook(runbook, "go", subject)

      # The error is keyed so the run page can mark the exact placeholder row.
      assert error.step_id == "bad"
      assert error.runner_id == other.id
      assert error.reason != nil

      # Engine context check: account unchanged by the partial failure.
      assert account.id == runner.account_id
    end
  end

  describe "dispatch_next_batch/1 continuation authorization (BLOCKER-1)" do
    # An operator in the same account as the runbook's owner. The owner
    # authors + publishes (needs manage_runbooks); the operator dispatches
    # (needs only dispatch_run) — so the owner can revoke the operator's
    # scope / suspend them mid-execution.
    defp operator_in(account) do
      user = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "operator"
        )

      {Fixtures.Memberships.fetch_membership(account.id, user.id),
       Fixtures.Subjects.subject_for(user, account)}
    end

    setup do
      {account, owner, runner} = account_with_runner()
      {membership, operator} = operator_in(account)

      %{
        account: account,
        owner: owner,
        runner: runner,
        membership: membership,
        operator: operator
      }
    end

    test "a runner scope revoked between waves stops the later wave reaching it", %{
      account: account,
      owner: owner,
      runner: runner,
      membership: membership,
      operator: operator
    } do
      other = Fixtures.Runners.create_runner(account_id: account.id)

      runbook = published_runbook!(owner, "scoped-book", uptime_steps(7, runner_target(runner)))

      assert {:ok, %{execution_id: execution_id, runs: wave1}} =
               Runbooks.dispatch_runbook(runbook, "go", operator)

      assert length(wave1) == 5

      # Narrow the initiating membership to a DIFFERENT runner — `runner` is now
      # out of scope for every later wave.
      assert {:ok, :ok} = Runners.replace_runner_scopes(membership, [{"runner", other.id}], owner)

      Enum.each(wave1, &finish!/1)

      # Steps 6-7 never dispatch: the continuation threads the initiating
      # membership and re-runs the scope check, refusing the now-out-of-scope
      # runner instead of bypassing it with a nil membership.
      assert length(execution_runs(account, execution_id)) == 5
    end

    test "a runner added to a selected group between waves is not picked up", %{
      account: account,
      owner: owner,
      runner: runner,
      operator: operator
    } do
      # 7 steps × 1 group runner = 7 items → 2 waves.
      runbook =
        published_runbook!(owner, "frozen-book", uptime_steps(7, group_target(runner.group)))

      assert {:ok, %{execution_id: execution_id, runs: wave1}} =
               Runbooks.dispatch_runbook(runbook, "go", operator)

      assert length(wave1) == 5

      # A new active runner joins the targeted group mid-execution.
      latecomer = Fixtures.Runners.create_runner(account_id: account.id, group: runner.group)

      _ =
        Fixtures.Catalog.create_action(runner: latecomer, action_id: "linux.uptime", risk: "low")

      Enum.each(wave1, &finish!/1)

      runs = execution_runs(account, execution_id)
      # All 7 frozen items dispatch — but only on the original runner. The
      # latecomer is absent from the frozen work-list, so it runs nothing.
      assert length(runs) == 7
      refute Enum.any?(runs, &(&1.runner_id == latecomer.id))
    end

    test "the initiating membership suspended between waves halts the execution", %{
      account: account,
      owner: owner,
      runner: runner,
      membership: membership,
      operator: operator
    } do
      runbook = published_runbook!(owner, "suspend-book", uptime_steps(7, runner_target(runner)))

      assert {:ok, %{execution_id: execution_id, runs: wave1}} =
               Runbooks.dispatch_runbook(runbook, "go", operator)

      assert length(wave1) == 5

      # The member who started the run is suspended.
      assert {:ok, _} = Accounts.suspend_membership(membership, owner)

      Enum.each(wave1, &finish!/1)

      # No later wave: the continuation revalidates the anchor membership, finds
      # it inactive, and halts rather than dispatching unauthorized.
      assert length(execution_runs(account, execution_id)) == 5
    end

    test "a cross-account runner forged into the frozen work-list is refused", %{
      account: account,
      owner: owner,
      runner: runner,
      operator: operator
    } do
      foreign = Fixtures.Runners.create_runner()

      # 6 steps × 1 runner = 6 items → 2 waves (5 + 1).
      runbook = published_runbook!(owner, "forged-book", uptime_steps(6, runner_target(runner)))

      assert {:ok, %{execution_id: execution_id, runs: wave1}} =
               Runbooks.dispatch_runbook(runbook, "go", operator)

      assert length(wave1) == 5

      # Tamper with the persisted work-list so step 6 points at another
      # account's runner — the defense the continuation must not trust.
      execution = Repo.get!(RunbookExecution, execution_id)

      forged =
        Enum.map(execution.work_list, fn item ->
          if item["step_index"] == 5, do: %{item | "runner_id" => foreign.id}, else: item
        end)

      {:ok, _} = execution |> Ecto.Changeset.change(work_list: forged) |> Repo.update()

      Enum.each(wave1, &finish!/1)

      # The continuation's `runner_in_account` gate refuses the foreign runner;
      # no sixth run is created.
      runs = execution_runs(account, execution_id)
      assert length(runs) == 5
      refute Enum.any?(runs, &(&1.runner_id == foreign.id))
    end

    test "the execution deleted between waves halts the continuation", %{
      account: account,
      owner: owner,
      runner: runner,
      operator: operator
    } do
      runbook = published_runbook!(owner, "vanish-book", uptime_steps(7, runner_target(runner)))

      assert {:ok, %{execution_id: execution_id, runs: wave1}} =
               Runbooks.dispatch_runbook(runbook, "go", operator)

      assert length(wave1) == 5

      # The durable execution record (the authorization anchor) is deleted
      # mid-flight — as it would be if the account/runbook were torn down.
      execution = Repo.get!(RunbookExecution, execution_id)
      {:ok, _} = Repo.delete(execution)

      Enum.each(wave1, &finish!/1)

      # peek_execution returns nil → the continuation no-ops rather than
      # dispatching wave 2 without its anchor; the in-flight wave still settled.
      assert length(execution_runs(account, execution_id)) == 5
    end

    test "a frozen work-list index with no matching step is dropped; the rest rehydrate", %{
      account: account,
      owner: owner,
      runner: runner,
      operator: operator
    } do
      # 7 steps × 1 runner = 7 frozen items → wave 1 (5) + wave 2 (items 6,7).
      runbook = published_runbook!(owner, "drop-book", uptime_steps(7, runner_target(runner)))

      assert {:ok, %{execution_id: execution_id, runs: wave1}} =
               Runbooks.dispatch_runbook(runbook, "go", operator)

      assert length(wave1) == 5

      # Tamper the persisted work-list so item 6's step_index points PAST the
      # runbook's steps (the version it referenced went away). frozen_items must
      # drop only that index and still rehydrate item 7.
      execution = Repo.get!(RunbookExecution, execution_id)

      mangled =
        Enum.map(execution.work_list, fn item ->
          if item["step_index"] == 5, do: %{item | "step_index" => 99}, else: item
        end)

      {:ok, _} = execution |> Ecto.Changeset.change(work_list: mangled) |> Repo.update()

      Enum.each(wave1, &finish!/1)

      runs = execution_runs(account, execution_id)
      step_ids = step_ids(runs)
      # Item 6 (now index 99) contributes nothing; item 7 (index 6 → "step7")
      # still dispatches — so the count is 6, with step7 present and step6 gone.
      assert length(runs) == 6
      assert "step7" in step_ids
      refute "step6" in step_ids
    end
  end

  describe "subject_can_manage_runbooks?/1" do
    setup do
      {_user, account, owner} = Fixtures.Subjects.owner_subject()
      %{account: account, owner: owner}
    end

    test "is true for an owner (manage_runbooks)", %{owner: owner} do
      assert Runbooks.subject_can_manage_runbooks?(owner)
    end

    test "is true for an admin", %{account: account} do
      admin = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :admin)
      assert Runbooks.subject_can_manage_runbooks?(admin)
    end

    test "is false for an operator (view-only)", %{account: account} do
      operator =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :operator)

      refute Runbooks.subject_can_manage_runbooks?(operator)
    end

    test "is false for a viewer", %{account: account} do
      viewer = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :viewer)
      refute Runbooks.subject_can_manage_runbooks?(viewer)
    end
  end

  describe "Runs.fetch_active_runbook_execution/2 (refresh rehydration)" do
    setup do
      {_account, subject, runner} = account_with_runner()
      %{subject: subject, runner: runner}
    end

    test "returns the in-flight execution's runs (runner preloaded) while non-terminal", %{
      subject: subject,
      runner: runner
    } do
      runbook = published_runbook!(subject, "live", uptime_steps(2, group_target(runner.group)))
      {:ok, %{execution_id: execution_id}} = Runbooks.dispatch_runbook(runbook, "go", subject)

      assert {:ok, %{execution_id: ^execution_id, runs: runs}} =
               Emisar.Runs.fetch_active_runbook_execution(runbook.id, subject)

      assert runs != []
      assert Enum.all?(runs, &(&1.runbook_execution_id == execution_id))
      # :runner is preloaded — the rehydration row render reads run.runner.name.
      assert Enum.all?(runs, &(&1.runner.name == runner.name))
    end

    test "returns :not_found once every run in the latest execution is settled", %{
      subject: subject,
      runner: runner
    } do
      runbook = published_runbook!(subject, "done", uptime_steps(1, group_target(runner.group)))
      {:ok, %{runs: [run]}} = Runbooks.dispatch_runbook(runbook, "go", subject)
      {:ok, _} = Emisar.Runs.mark_finished(run, %{"status" => "success", "duration_ms" => 5})

      assert {:error, :not_found} =
               Emisar.Runs.fetch_active_runbook_execution(runbook.id, subject)
    end

    test "returns :not_found for a runbook that was never dispatched", %{
      subject: subject,
      runner: runner
    } do
      runbook = published_runbook!(subject, "fresh", uptime_steps(1, group_target(runner.group)))

      assert {:error, :not_found} =
               Emisar.Runs.fetch_active_runbook_execution(runbook.id, subject)
    end

    test "doesn't surface another account's execution", %{subject: subject, runner: runner} do
      runbook = published_runbook!(subject, "mine", uptime_steps(1, group_target(runner.group)))
      {:ok, _} = Runbooks.dispatch_runbook(runbook, "go", subject)

      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      assert {:error, :not_found} =
               Emisar.Runs.fetch_active_runbook_execution(runbook.id, subject_b)
    end
  end
end
