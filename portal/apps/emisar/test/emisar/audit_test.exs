defmodule Emisar.AuditTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Approvals, Audit, RequestContext, Runbooks, Runs, SSO}
  alias Emisar.Auth.Subject
  alias Emisar.Fixtures

  describe "log/3 with a %RequestContext{}" do
    setup do
      account = Fixtures.Accounts.create_account()
      %{account: account}
    end

    test "stamps IP/UA/request_id/mcp_session from the :context struct", %{account: account} do
      context = %RequestContext{
        ip_address: "10.0.0.42",
        user_agent: "curl/8.5.0",
        request_id: "req_abc",
        mcp_session_id: "sess_xyz"
      }

      {:ok, event} = Audit.log(account.id, "audit.test", actor_kind: "system", context: context)

      assert event.ip_address == "10.0.0.42"
      assert event.user_agent == "curl/8.5.0"
      assert event.request_id == "req_abc"
      assert event.mcp_session_id == "sess_xyz"
    end

    test "explicit attrs win over the context struct", %{account: account} do
      context = %RequestContext{ip_address: "10.0.0.42", user_agent: "curl"}

      {:ok, event} =
        Audit.log(account.id, "audit.test",
          actor_kind: "system",
          context: context,
          ip_address: "8.8.8.8"
        )

      assert event.ip_address == "8.8.8.8"
      # user_agent NOT explicitly overridden — still taken from the context.
      assert event.user_agent == "curl"
    end

    test "with no :context, request metadata is nil (system / engine origin)", %{account: account} do
      {:ok, event} = Audit.log(account.id, "audit.test", actor_kind: "system")

      assert event.ip_address == nil
      assert event.user_agent == nil
      assert event.request_id == nil
      assert event.mcp_session_id == nil
    end

    test "over-long request metadata is truncated, not rejected (audit can't be evaded)", %{
      account: account
    } do
      {:ok, event} =
        Audit.log(account.id, "audit.test",
          actor_kind: "system",
          user_agent: String.duplicate("A", 500)
        )

      # The insert SUCCEEDS — a giant `user-agent` on a failed sign-in
      # can't suppress the audit row — and the value is bounded to the
      # varchar(255) column rather than overflowing it.
      assert String.length(event.user_agent) == 255
    end

    # normalize/1 uses String.to_existing_atom (IL-14): an
    # invented field name blows up LOUDLY rather than minting an atom from input
    # (the atom table never GCs; an attacker-influenced key set would be a DoS).
    test "an invented string field key raises rather than minting an atom (IL-14)", %{
      account: account
    } do
      assert_raise ArgumentError, fn ->
        Audit.log(account.id, "audit.test", %{
          "actor_kind" => "system",
          "this_audit_field_was_never_declared_zqx" => "x"
        })
      end
    end
  end

  describe "record/1" do
    test "inserts a prebuilt Audit.Events changeset and returns {:ok, %Event{}}" do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      assert {:ok, %Audit.Event{} = event} =
               Audit.record(Audit.Events.account_updated(subject, account))

      assert event.event_type == "account.updated"
      assert event.account_id == account.id
      # The row is persisted, not just built.
      assert Repo.reload!(event).id == event.id
    end

    test "an invalid changeset surfaces {:error, %Ecto.Changeset{}} (no insert)" do
      account = Fixtures.Accounts.create_account()
      before = Repo.aggregate(Audit.Event, :count, :id)

      # event_type is required; an empty one fails the changeset rather than writing.
      assert {:error, %Ecto.Changeset{}} = Audit.record(Audit.changeset(account.id, ""))
      assert Repo.aggregate(Audit.Event, :count, :id) == before
    end
  end

  describe "changeset/3" do
    setup do
      account = Fixtures.Accounts.create_account()
      %{account: account}
    end

    test "builds a valid, un-inserted changeset stamping account/type/occurred_at", %{
      account: account
    } do
      before = Repo.aggregate(Audit.Event, :count, :id)

      changeset = Audit.changeset(account.id, "audit.test", actor_kind: "system")

      assert %Ecto.Changeset{valid?: true} = changeset
      assert Ecto.Changeset.get_field(changeset, :account_id) == account.id
      assert Ecto.Changeset.get_field(changeset, :event_type) == "audit.test"
      assert %DateTime{} = Ecto.Changeset.get_field(changeset, :occurred_at)
      # Build-only — nothing is written until record/log inserts it.
      assert Repo.aggregate(Audit.Event, :count, :id) == before
    end

    test "merge order is base < request context < explicit attrs", %{account: account} do
      context = %RequestContext{ip_address: "10.0.0.9", user_agent: "ctx-ua"}

      changeset =
        Audit.changeset(account.id, "audit.test",
          actor_kind: "system",
          context: context,
          ip_address: "8.8.8.8"
        )

      # Explicit ip wins over the context; un-overridden ua falls through from it.
      assert Ecto.Changeset.get_field(changeset, :ip_address) == "8.8.8.8"
      assert Ecto.Changeset.get_field(changeset, :user_agent) == "ctx-ua"
    end

    test "an invented string field key raises rather than minting an atom (IL-14)", %{
      account: account
    } do
      assert_raise ArgumentError, fn ->
        Audit.changeset(account.id, "audit.test", %{
          "actor_kind" => "system",
          "never_declared_audit_field_qzx" => "x"
        })
      end
    end
  end

  describe "log_for_user/3 without a membership" do
    # a user with no active membership can't be scoped to an
    # account_id, so the event is silently skipped (returns :ok, writes nothing)
    # rather than raising or writing an account-less row.
    test "no-ops (returns :ok) and writes no row when the user has no membership" do
      user = Fixtures.Users.create_user()
      before = Repo.aggregate(Audit.Event, :count, :id)

      assert :ok = Audit.log_for_user(user, "user.signed_in", actor_kind: "user")
      assert Repo.aggregate(Audit.Event, :count, :id) == before
    end
  end

  describe "user_changesets/3" do
    test "one changeset per active membership, each stamped with the user defaults" do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "owner"
        )

      assert [changeset] = Audit.user_changesets(user, "user.signed_in")

      assert %Ecto.Changeset{valid?: true} = changeset
      # Scoped onto the user's account…
      assert Ecto.Changeset.get_field(changeset, :account_id) == account.id
      # …with the user-scoped defaults derived from the user row.
      assert Ecto.Changeset.get_field(changeset, :actor_kind) == "user"
      assert Ecto.Changeset.get_field(changeset, :actor_id) == user.id
      assert Ecto.Changeset.get_field(changeset, :target_kind) == "user"
      assert Ecto.Changeset.get_field(changeset, :target_id) == user.id
      assert Ecto.Changeset.get_field(changeset, :target_label) == user.email
    end

    test "fans out to every account the user is an active member of" do
      user = Fixtures.Users.create_user()
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()
      _ = Fixtures.Memberships.create_membership(account_id: account_a.id, user_id: user.id)
      _ = Fixtures.Memberships.create_membership(account_id: account_b.id, user_id: user.id)

      changesets = Audit.user_changesets(user, "user.signed_in")

      account_ids = Enum.map(changesets, &Ecto.Changeset.get_field(&1, :account_id))
      assert Enum.sort(account_ids) == Enum.sort([account_a.id, account_b.id])
    end

    test "attrs override the defaults on every row" do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()
      _ = Fixtures.Memberships.create_membership(account_id: account.id, user_id: user.id)

      assert [changeset] = Audit.user_changesets(user, "user.signed_in", actor_kind: "system")
      assert Ecto.Changeset.get_field(changeset, :actor_kind) == "system"
    end

    test "returns [] (skip) when the user has no active membership" do
      user = Fixtures.Users.create_user()

      assert Audit.user_changesets(user, "user.signed_in") == []
    end
  end

  describe "run_event_changeset/1" do
    # request_id + mcp_session_id are promoted to first-class
    # fields (not buried in payload), and nil payload keys are compacted so a
    # freshly-created run's row doesn't bloat with still-empty fields.
    test "promotes request_id + mcp_session_id and drops nil payload keys" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "operator",
          args: %{}
        })

      changeset = Audit.run_event_changeset(run)

      assert Ecto.Changeset.get_field(changeset, :request_id) == run.request_id
      assert Ecto.Changeset.get_field(changeset, :mcp_session_id) == run.mcp_session_id

      # The changeset payload carries atom keys (compact/1 builds an atom-keyed
      # map; JSON serialization to string keys happens at insert time).
      payload = Ecto.Changeset.get_field(changeset, :payload)
      # What ran + the run's identity are payload facts; the still-nil
      # fields are compacted out.
      assert payload[:action] == "linux.uptime"
      assert payload[:run_id] == run.id
      refute Map.has_key?(payload, :exit_code)
      refute Map.has_key?(payload, :duration_ms)
      refute Map.has_key?(payload, :executed_command)
    end
  end

  describe "run_target/1" do
    # The target answers WHERE: run-family rows target the runner the run
    # executed on (pivoting on it yields the host's whole history); what ran
    # rides in the payload.
    test "targets the runner, labeled with its name" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "operator",
          args: %{}
        })

      assert Audit.run_target(run) == [
               target_kind: "runner",
               target_id: runner.id,
               target_label: runner.name
             ]
    end

    test "labels from the loaded runner assoc without a lookup, and survives a missing runner" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "operator",
          args: %{}
        })

      loaded = %{run | runner: %{runner | name: "already-loaded"}}
      assert Audit.run_target(loaded)[:target_label] == "already-loaded"

      # A hard-deleted runner (beyond soft-delete) still yields a usable
      # target — the id stands, the label is simply absent.
      gone = %{run | runner_id: Ecto.UUID.generate()}
      assert Audit.run_target(gone)[:target_label] == nil
    end
  end

  describe "system/engine-origin builders carry no caller request metadata" do
    # An engine-written run event is system-origin (no %Subject{}), so it inherits
    # NO caller ip/ua/mcp_session — the runner-UA-bleed class of bug. It DOES carry
    # the run's OWN request_id (the intended audit↔run link, not a context bleed).
    test "a system-origin run event carries no caller ip/ua/mcp_session" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "operator",
          args: %{}
        })

      {:ok, event} = Audit.record(Audit.run_event_changeset(run))

      assert event.actor_kind == "system"
      assert event.ip_address == nil
      assert event.user_agent == nil
      assert event.mcp_session_id == nil
      # The run's own request_id is correlated (links the audit row to the run);
      # it is NOT a caller's bled-through request id.
      assert event.request_id == run.request_id
    end
  end

  describe "Audit.Events builders inherit the subject's request context" do
    setup do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "owner"
        )

      %{account: account, user: user}
    end

    test "a builder stamps actor + the subject's context onto the event", %{
      user: user,
      account: account
    } do
      context = %RequestContext{
        ip_address: "203.0.113.7",
        user_agent: "Mozilla/5.0",
        request_id: "req_evt",
        mcp_session_id: "sess_evt"
      }

      subject = Fixtures.Subjects.subject_for(user, account, role: :owner, context: context)

      {:ok, event} = Audit.record(Audit.Events.account_updated(subject, account))

      # Actor identity comes off the subject…
      assert event.actor_kind == "user"
      assert event.actor_id == user.id
      # …and so does the request metadata — the lever that lets every
      # builder inherit ip/ua/request_id/mcp_session without threading a conn.
      assert event.ip_address == "203.0.113.7"
      assert event.user_agent == "Mozilla/5.0"
      assert event.request_id == "req_evt"
      assert event.mcp_session_id == "sess_evt"
    end

    test "a subject with the default (empty) context yields no request metadata", %{
      user: user,
      account: account
    } do
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      {:ok, event} = Audit.record(Audit.Events.account_updated(subject, account))

      assert event.actor_id == user.id
      assert event.ip_address == nil
      assert event.user_agent == nil
      assert event.request_id == nil
      assert event.mcp_session_id == nil
    end

    test "a builder stamps the subject's auth provenance onto the event", %{
      user: user,
      account: account
    } do
      identity_id = Repo.generate_id()

      subject =
        Fixtures.Subjects.subject_for(user, account,
          role: :owner,
          auth_method: :sso,
          mfa: true,
          user_identity_id: identity_id
        )

      {:ok, event} = Audit.record(Audit.Events.account_updated(subject, account))

      # How the actor authenticated rides the subject onto every audit row
      # (decision 6) — string method for the column, the mfa flag, and the
      # identity id for SSO.
      assert event.auth_method == "sso"
      assert event.mfa == true
      assert event.user_identity_id == identity_id
    end

    test "a subject with no auth method leaves the provenance fields nil", %{
      user: user,
      account: account
    } do
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      {:ok, event} = Audit.record(Audit.Events.account_updated(subject, account))

      assert event.auth_method == nil
      assert event.user_identity_id == nil
    end
  end

  describe "subscribe_account_audit/1" do
    test "the subscriber receives the account's audit fan-out, not another account's" do
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()

      {:ok, event_a} = Audit.log(account_a.id, "user.signed_in", actor_kind: "user")
      {:ok, event_b} = Audit.log(account_b.id, "user.signed_in", actor_kind: "user")

      assert :ok = Audit.subscribe_account_audit(account_a.id)

      # A's event fans onto A's topic — the subscriber gets it…
      Audit.broadcast_event(event_a)
      assert_receive {:audit_event, %Audit.Event{} = received}
      assert received.id == event_a.id

      # …but B's event publishes on B's topic, which A never joined, so A's
      # mailbox stays empty (A's own event was already consumed above).
      Audit.broadcast_event(event_b)
      refute_receive {:audit_event, _event}
    end
  end

  describe "broadcast_event/1" do
    test "publishes {:audit_event, event} on the event's own account topic" do
      account = Fixtures.Accounts.create_account()
      {:ok, event} = Audit.log(account.id, "user.signed_in", actor_kind: "user")

      :ok = Audit.subscribe_account_audit(account.id)

      assert :ok = Audit.broadcast_event(event)
      assert_receive {:audit_event, %Audit.Event{} = received}
      assert received.id == event.id
      assert received.account_id == account.id
    end

    test "a subscriber to another account does not receive it (topic is account-scoped)" do
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()
      {:ok, event_b} = Audit.log(account_b.id, "user.signed_in", actor_kind: "user")

      # Subscribe to A, broadcast B's event — A's subscriber must hear nothing.
      :ok = Audit.subscribe_account_audit(account_a.id)

      assert :ok = Audit.broadcast_event(event_b)
      refute_receive {:audit_event, _event}
    end
  end

  describe "list_events/2 (paginated + filterable)" do
    setup do
      account = Fixtures.Accounts.create_account()
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)
      %{account: account, subject: subject}
    end

    test "page size + Next cursor walk through every row in order", %{
      account: account,
      subject: subject
    } do
      for i <- 1..7 do
        {:ok, _} =
          Audit.log(account.id, "iter.event",
            actor_kind: "system",
            payload: %{"i" => i}
          )
      end

      # First page of 3 — Next cursor points to the rest.
      assert {:ok, page1, %{next_page_cursor: cursor, count: 7}} =
               Audit.list_events(subject, page: [limit: 3])

      assert length(page1) == 3
      assert is_binary(cursor)

      {:ok, page2, %{next_page_cursor: cursor2}} =
        Audit.list_events(subject, page: [cursor: cursor, limit: 3])

      assert length(page2) == 3

      {:ok, page3, %{next_page_cursor: nil}} =
        Audit.list_events(subject, page: [cursor: cursor2, limit: 3])

      # Last page tail — 7 - 3 - 3 = 1 row.
      assert length(page3) == 1

      # No row repeated across pages — keyset pagination invariant.
      ids = Enum.map(page1 ++ page2 ++ page3, & &1.id)
      assert ids == Enum.uniq(ids)
    end

    test "filter list narrows to matching event_types only", %{
      account: account,
      subject: subject
    } do
      # Use real known event_type values — the filter now validates
      # against `Event.Query.known_event_type_values/0` so the UI
      # dropdown shows curated options instead of free-text.
      {:ok, _} = Audit.log(account.id, "user.invited", actor_kind: "user")
      {:ok, _} = Audit.log(account.id, "policy.updated", actor_kind: "user")
      {:ok, _} = Audit.log(account.id, "user.invited", actor_kind: "user")

      {:ok, rows, %{count: 2}} =
        Audit.list_events(subject, filter: [event_type: ["user.invited"]])

      assert length(rows) == 2
      assert Enum.all?(rows, &(&1.event_type == "user.invited"))
    end

    test "the SSO / Directory event types are selectable in both filter lists" do
      flat =
        Audit.Event.Query.known_event_type_values() |> Enum.map(&elem(&1, 0)) |> MapSet.new()

      grouped =
        Audit.Event.Query.grouped_event_type_values()
        |> Enum.flat_map(fn {_group, items} -> Enum.map(items, &elem(&1, 0)) end)
        |> MapSet.new()

      sso = ~w[
        user.provisioned_via_sso user.provisioned_via_scim
        membership.deprovisioned_via_scim membership.reprovisioned_via_scim
        membership.role_synced_via_scim
        sso.group_mapping_created sso.group_mapping_updated sso.group_mapping_deleted
        sso.link_request_approved sso.link_request_dismissed
      ]

      for type <- sso do
        assert type in flat, "#{type} missing from known_event_type_values/0"
        assert type in grouped, "#{type} missing from grouped_event_type_values/0"
      end
    end

    test "the request_id filter matches an anchored prefix, with wildcards escaped", %{
      account: account,
      subject: subject
    } do
      log = fn type, req_id ->
        {:ok, _} =
          Audit.log(account.id, type,
            actor_kind: "system",
            context: %RequestContext{request_id: req_id}
          )
      end

      log.("policy.updated", "req_trace")
      # A would-be wildcard collision: if `_` weren't escaped, searching
      # "req_tr" would also match this.
      log.("user.invited", "reqZtrace")
      # A would-be infix collision: the filter stays prefix-anchored so the
      # request_id index can serve it.
      log.("user.signed_in", "xreq_trace")

      # Paste the leading fragment: only its event; the `_` is matched literally.
      assert {:ok, [hit], %{count: 1}} =
               Audit.list_events(subject, filter: [request_id: "req_tr"])

      assert hit.request_id == "req_trace"
    end

    test "actor_kind list filter accepts a list of kinds", %{account: account, subject: subject} do
      {:ok, _} = Audit.log(account.id, "x", actor_kind: "user")
      {:ok, _} = Audit.log(account.id, "x", actor_kind: "api_key")
      {:ok, _} = Audit.log(account.id, "x", actor_kind: "system")

      {:ok, rows, _} =
        Audit.list_events(subject, filter: [actor_kind: ["user", "api_key"]])

      assert length(rows) == 2
      assert Enum.all?(rows, &(&1.actor_kind in ["user", "api_key"]))
    end

    test "invalid cursor surfaces an error rather than returning random rows", %{subject: subject} do
      assert {:error, :invalid_cursor} =
               Audit.list_events(subject, page: [cursor: "garbage"])
    end

    test "a well-formed but type-mismatched cursor is :invalid_cursor, not a 500", %{
      account: account,
      subject: subject
    } do
      {:ok, _} = Audit.log(account.id, "user.invited", actor_kind: "user")

      # Event's keyset is [{:events, :desc, :occurred_at}, {:events, :asc, :id}].
      # Forge a cursor that decodes cleanly (a real DateTime + a string) but
      # carries a string where the UUID `id` column is expected — it survives
      # the :safe decode + nil-check and only fails when the keyset WHERE is
      # bound. Previously that raised a self-inflicted 500.
      now_ns = DateTime.to_unix(DateTime.utc_now(), :nanosecond)

      cursor =
        {:after, [{DateTime, now_ns}, {:t, "not-a-uuid"}]}
        |> :erlang.term_to_binary()
        |> Base.url_encode64(padding: false)

      assert {:error, :invalid_cursor} =
               Audit.list_events(subject, page: [cursor: cursor])
    end

    # The "Hide noisy events" toggle is retired (audit-logging diet): once
    # policy.evaluated stopped emitting there was no noise class left to hide.
    # The filter is gone from the bar, so a stale ?hide_noise=true URL param is
    # simply dropped at the web boundary (params_to_opts keeps only declared
    # filters) — no crash, nothing hidden.
    test "the hide_noise filter is retired" do
      refute Enum.any?(Audit.Event.Query.filters(), &(&1.name == :hide_noise))
    end

    test "outcome filter narrows to failures (danger) and denials (warn) by suffix", %{
      account: account,
      subject: subject
    } do
      {:ok, _} = Audit.log(account.id, "action_run.failed", actor_kind: "system")
      {:ok, _} = Audit.log(account.id, "approval.denied", actor_kind: "user")
      {:ok, _} = Audit.log(account.id, "approval.approved", actor_kind: "user")

      # "danger" keeps only the failure; routine (approved) is excluded.
      {:ok, danger, _} = Audit.list_events(subject, filter: [outcome: ["danger"]])
      assert Enum.map(danger, & &1.event_type) == ["action_run.failed"]

      # Both outcomes keep the failure + the denial, still dropping the pass.
      {:ok, both, _} = Audit.list_events(subject, filter: [outcome: ["danger", "warn"]])
      kept = Enum.map(both, & &1.event_type) |> Enum.sort()
      assert kept == ["action_run.failed", "approval.denied"]

      # "pass" keeps only the yes-verdict.
      {:ok, passes, _} = Audit.list_events(subject, filter: [outcome: ["pass"]])
      assert Enum.map(passes, & &1.event_type) == ["approval.approved"]
    end

    test "the Type filter scopes to a whole group via the 'All <group>' option", %{
      account: account,
      subject: subject
    } do
      {:ok, _} = Audit.log(account.id, "runner.connected", actor_kind: "runner")
      {:ok, _} = Audit.log(account.id, "runner.disabled", actor_kind: "user")
      {:ok, _} = Audit.log(account.id, "approval.approved", actor_kind: "user")

      # "All Runner events" (the group:Runner sentinel) expands to every type in the
      # Runner group — both runner rows, not the approval one.
      {:ok, rows, _} = Audit.list_events(subject, filter: [event_type: ["group:Runner"]])

      assert Enum.map(rows, & &1.event_type) |> Enum.sort() == [
               "runner.connected",
               "runner.disabled"
             ]

      # A plain type still works (and can mix with a group sentinel).
      {:ok, one, _} = Audit.list_events(subject, filter: [event_type: ["approval.approved"]])
      assert Enum.map(one, & &1.event_type) == ["approval.approved"]
    end

    test "each event-type group leads with its selectable '<Group> — all events' header" do
      options = Audit.Event.Query.event_type_filter_options()

      assert {"Runner", [{"group:Runner", "Runner — all events", group_description} | rest]} =
               Enum.find(options, fn {label, _} -> label == "Runner" end)

      assert group_description == "Every Runner event."
      # Every option carries its hover description.
      assert Enum.all?(rest, fn {_value, _label, description} -> is_binary(description) end)
    end

    test "conditional filters only apply to types that carry them" do
      filters = Audit.Event.Query.filters()
      names = fn applicable -> Enum.map(applicable, & &1.name) end

      # account.created happens at sign-up, pre-session — neither request_id
      # nor auth_method is ever stamped on it.
      applicable = Audit.Event.Query.applicable_filters(filters, "account.created")
      refute :request_id in names.(applicable)
      refute :auth_method in names.(applicable)

      # A run terminal carries the dispatching request but no sign-in method
      # (API keys don't sign in).
      applicable = Audit.Event.Query.applicable_filters(filters, "action_run.success")
      assert :request_id in names.(applicable)
      refute :auth_method in names.(applicable)

      # An admin action carries both.
      applicable = Audit.Event.Query.applicable_filters(filters, "membership.role_changed")
      assert :request_id in names.(applicable)
      assert :auth_method in names.(applicable)

      # A group sentinel applies a filter when ANY of its types supports it.
      applicable = Audit.Event.Query.applicable_filters(filters, "group:Account")
      assert :auth_method in names.(applicable)

      # Sign-up happens pre-session — no request context is ever stamped.
      applicable = Audit.Event.Query.applicable_filters(filters, "user.signed_up")
      refute :request_id in names.(applicable)

      # Target type is meaningless for self-events (a sign-in acts on its own
      # actor) — hidden for them, but KEPT on the mixed stream (no Type).
      applicable = Audit.Event.Query.applicable_filters(filters, "user.signed_in")
      refute :target_kind in names.(applicable)

      applicable = Audit.Event.Query.applicable_filters(filters, "membership.role_changed")
      assert :target_kind in names.(applicable)

      applicable = Audit.Event.Query.applicable_filters(filters, nil)
      assert :target_kind in names.(applicable)

      # A LIVE param keeps its conditional facet applicable regardless of Type —
      # a trace link (`?request_id=…` from a run's "View activity") must filter,
      # never silently show the whole trail.
      applicable = Audit.Event.Query.applicable_filters(filters, nil, %{"request_id" => "req_x"})
      assert :request_id in names.(applicable)

      # …but a blank param is no param.
      applicable = Audit.Event.Query.applicable_filters(filters, nil, %{"request_id" => ""})
      refute :request_id in names.(applicable)
    end

    test "actor_id narrows the list to one identity", %{account: account, subject: subject} do
      actor_a = Ecto.UUID.generate()
      actor_b = Ecto.UUID.generate()
      {:ok, _} = Audit.log(account.id, "x", actor_kind: "user", actor_id: actor_a)
      {:ok, _} = Audit.log(account.id, "x", actor_kind: "user", actor_id: actor_b)

      {:ok, events, _} = Audit.list_events(subject, actor_id: actor_a)
      assert Enum.map(events, & &1.actor_id) == [actor_a]
    end

    test "target_id narrows the list to one subject", %{account: account, subject: subject} do
      subj_a = Ecto.UUID.generate()
      subj_b = Ecto.UUID.generate()
      {:ok, _} = Audit.log(account.id, "x", target_kind: "user", target_id: subj_a)
      {:ok, _} = Audit.log(account.id, "x", target_kind: "user", target_id: subj_b)

      {:ok, events, _} = Audit.list_events(subject, target_id: subj_a)
      assert Enum.map(events, & &1.target_id) == [subj_a]
    end

    test "the from / to date-range filters bound the window", %{
      account: account,
      subject: subject
    } do
      {:ok, _} = Audit.log(account.id, "x", actor_kind: "system")

      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      # from/to are LiveTable %Filter{} datetime filters now — applied via :filter.
      assert {:ok, [], _} = Audit.list_events(subject, filter: [from: future])
      assert {:ok, [_ | _], _} = Audit.list_events(subject, filter: [to: future])
      assert {:ok, [_ | _], _} = Audit.list_events(subject, filter: [from: past])
    end

    test "actor_id can't surface another account's events" do
      account_a = Fixtures.Accounts.create_account()

      subject_a =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account_a, role: :owner)

      account_b = Fixtures.Accounts.create_account()
      actor = Ecto.UUID.generate()
      {:ok, _} = Audit.log(account_b.id, "x", actor_kind: "user", actor_id: actor)

      assert {:ok, [], _} = Audit.list_events(subject_a, actor_id: actor)
    end

    test "a runner subject (no view_audit) is denied" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      subject = Subject.for_runner(runner, account)

      assert {:error, :unauthorized} = Audit.list_events(subject)
    end
  end

  describe "the From/To window is inclusive on both bounds" do
    setup do
      account = Fixtures.Accounts.create_account()
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)
      %{account: account, subject: subject}
    end

    # From == an event's exact occurred_at INCLUDES it
    # (`occurred_at >= ts`), and To == an event's exact occurred_at INCLUDES it
    # (`occurred_at <= ts`); the boundary row is never silently dropped.
    test "an event at the exact From bound and at the exact To bound are both kept", %{
      account: account,
      subject: subject
    } do
      early = DateTime.add(DateTime.utc_now(), -7200, :second)
      late = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, e_early} =
        Audit.log(account.id, "user.invited", actor_kind: "user", occurred_at: early)

      {:ok, e_late} =
        Audit.log(account.id, "policy.updated", actor_kind: "user", occurred_at: late)

      # From == early's timestamp keeps both (early is on the inclusive bound).
      {:ok, from_rows, _} = Audit.list_events(subject, filter: [from: early])
      assert Enum.sort(Enum.map(from_rows, & &1.id)) == Enum.sort([e_early.id, e_late.id])

      # To == early's timestamp keeps ONLY early (late is past the upper bound),
      # and early is included because the upper bound is inclusive too.
      {:ok, to_rows, _} = Audit.list_events(subject, filter: [to: early])
      assert Enum.map(to_rows, & &1.id) == [e_early.id]
    end
  end

  describe "keyset pagination: empty / last page yields no further cursor" do
    setup do
      account = Fixtures.Accounts.create_account()
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)
      %{account: account, subject: subject}
    end

    # an empty account returns a nil next cursor, and the
    # final page of a multi-page walk also returns nil (nothing further to fetch),
    # which is what pairs with the empty-state copy in the LV.
    test "an empty log returns no next-page cursor", %{subject: subject} do
      assert {:ok, [], %{next_page_cursor: nil}} = Audit.list_events(subject, page: [limit: 5])
    end

    test "the last page of a walk has a nil next cursor", %{account: account, subject: subject} do
      for _ <- 1..4, do: {:ok, _} = Audit.log(account.id, "user.invited", actor_kind: "user")

      # 4 rows, page size 3 → page 1 has a cursor, page 2 (the last) does not.
      {:ok, _page1, %{next_page_cursor: cursor}} = Audit.list_events(subject, page: [limit: 3])
      assert is_binary(cursor)

      assert {:ok, [_], %{next_page_cursor: nil}} =
               Audit.list_events(subject, page: [cursor: cursor, limit: 3])
    end

    # a row committed mid-walk must not shift a page
    # boundary into a skip or a duplicate. The feed is keyset (cursor on
    # `(occurred_at desc, id asc)`), not offset: the cursor anchors on page 1's
    # last row, so resuming continues strictly past it regardless of inserts.
    # A fresh row sorts at the FRONT (newest `occurred_at`), ahead of page 1, so
    # it is never paged into the resumed walk, and every original row is still
    # seen exactly once across the two pages.
    test "a row inserted between page loads doesn't skip or duplicate the walk", %{
      account: account,
      subject: subject
    } do
      # Six rows, each strictly older than "now" and strictly ordered among
      # themselves (descending occurred_at == older `i` last), so the walk order
      # is deterministic and the mid-walk insert lands ahead of all of them.
      base = DateTime.add(DateTime.utc_now(), -3600, :second)

      seeded =
        for i <- 1..6 do
          {:ok, event} =
            Audit.log(account.id, "iter.event",
              actor_kind: "system",
              payload: %{"i" => i},
              occurred_at: DateTime.add(base, i, :second)
            )

          event.id
        end

      {:ok, page1, %{next_page_cursor: cursor}} = Audit.list_events(subject, page: [limit: 3])
      assert length(page1) == 3
      assert is_binary(cursor)

      # Commit a brand-new event AFTER page 1 was read but BEFORE page 2 — it
      # gets `occurred_at = now`, so it sorts newest (at the front).
      {:ok, fresh} = Audit.log(account.id, "iter.event", actor_kind: "system")

      {:ok, page2, _meta} = Audit.list_events(subject, page: [cursor: cursor, limit: 3])

      walked = Enum.map(page1 ++ page2, & &1.id)

      # No row appears twice across the two pages (no duplicate at the boundary).
      assert walked == Enum.uniq(walked)
      # The fresh front row is never paged into the resumed walk — the cursor
      # anchored past page 1's last row, so the walk only moves toward older rows.
      refute fresh.id in walked
      # Every originally-seeded row is seen exactly once — none skipped.
      assert MapSet.new(walked) == MapSet.new(seeded)
    end
  end

  describe "list_actor_options/2 (the dynamic actor picker)" do
    setup do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: owner.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      %{account: account, owner: owner, subject: subject}
    end

    test "returns distinct actors of the kind with resolved labels, sorted", %{
      account: account,
      subject: subject
    } do
      alice = Fixtures.Users.create_user(email: "alice@example.com")
      bob = Fixtures.Users.create_user(email: "bob@example.com")
      _ = Fixtures.Memberships.create_membership(account_id: account.id, user_id: alice.id)
      _ = Fixtures.Memberships.create_membership(account_id: account.id, user_id: bob.id)

      # Two events for bob, one for alice — the picker dedupes to one option per
      # actor, sorted by label (alice precedes bob regardless of event order).
      {:ok, _} = Audit.log(account.id, "x", actor_kind: "user", actor_id: bob.id)
      {:ok, _} = Audit.log(account.id, "y", actor_kind: "user", actor_id: bob.id)
      {:ok, _} = Audit.log(account.id, "z", actor_kind: "user", actor_id: alice.id)

      assert {:ok, [{alice_id, "alice@example.com"}, {bob_id, "bob@example.com"}]} =
               Audit.list_actor_options("user", subject)

      assert alice_id == alice.id
      assert bob_id == bob.id
    end

    test "ensure: forces a zero-event member into the options (View-activity click-through)", %{
      account: account,
      subject: subject
    } do
      # A member who has never acted — not in the log, so absent by default.
      quiet = Fixtures.Users.create_user(email: "quiet@example.com")
      _ = Fixtures.Memberships.create_membership(account_id: account.id, user_id: quiet.id)

      assert {:ok, []} = Audit.list_actor_options("user", subject)

      # ensure them in so the picker SELECTS them instead of falling back to All.
      assert {:ok, [{id, "quiet@example.com"}]} =
               Audit.list_actor_options("user", subject, ensure: quiet.id)

      assert id == quiet.id

      # An id that isn't a member of this account resolves to no label → dropped.
      stranger = Fixtures.Users.create_user(email: "stranger@example.com")
      assert {:ok, []} = Audit.list_actor_options("user", subject, ensure: stranger.id)

      # nil ensure is a no-op.
      assert {:ok, []} = Audit.list_actor_options("user", subject, ensure: nil)
    end

    test "scopes to the requested kind only", %{
      account: account,
      owner: owner,
      subject: subject
    } do
      member = Fixtures.Users.create_user()
      _ = Fixtures.Memberships.create_membership(account_id: account.id, user_id: member.id)

      {_raw, key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: owner.id)

      {:ok, _} = Audit.log(account.id, "u", actor_kind: "user", actor_id: member.id)
      {:ok, _} = Audit.log(account.id, "k", actor_kind: "api_key", actor_id: key.id)

      assert {:ok, [{id, _label}]} = Audit.list_actor_options("api_key", subject)
      assert id == key.id
    end

    test "drops an actor only resolvable in another account (no cross-tenant leak)" do
      account_a = Fixtures.Accounts.create_account()

      subject_a =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account_a, role: :owner)

      user_b = Fixtures.Users.create_user()
      account_b = Fixtures.Accounts.create_account()
      _ = Fixtures.Memberships.create_membership(account_id: account_b.id, user_id: user_b.id)

      # A's log references B's user (a mis-stamped id): it lives in A's events
      # but is only resolvable in B, so it must not surface in A's picker.
      {:ok, _} = Audit.log(account_a.id, "x", actor_kind: "user", actor_id: user_b.id)

      assert {:ok, []} = Audit.list_actor_options("user", subject_a)
    end

    test "a kind with no resolvable actors yields no options" do
      account = Fixtures.Accounts.create_account()
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)
      {:ok, _} = Audit.log(account.id, "x", actor_kind: "system", actor_id: Ecto.UUID.generate())

      assert {:ok, []} = Audit.list_actor_options("system", subject)
    end

    # the actor picker enforces view_audit before any DB
    # touch; a runner (websocket) subject — no view_audit — is denied.
    test "a runner subject is denied" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      subject = Subject.for_runner(runner, account)

      assert {:error, :unauthorized} = Audit.list_actor_options("user", subject)
    end
  end

  describe "list_target_options/2 (the dynamic subject picker)" do
    # the picker read enforces view_audit BEFORE any DB
    # touch; a runner subject (the websocket caller — no view_audit) is denied,
    # never handed options. A real `Subject.for_runner` carries the runner role's
    # empty audit permission (a user `:runner` string would degrade to :viewer,
    # which CAN view — so the websocket subject is the genuine no-permission one).
    test "a runner subject (no view_audit) is denied (no DB touch)" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      subject = Subject.for_runner(runner, account)

      assert {:error, :unauthorized} = Audit.list_target_options("user", subject)
    end

    # a subject id that only resolves in account A never
    # surfaces in account B's picker: the distinct-id query is for_subject-scoped
    # to B, so A's row isn't even a candidate.
    test "a subject only resolvable in another account yields no options (cross-account)" do
      account_a = Fixtures.Accounts.create_account()

      subject_b =
        Fixtures.Subjects.subject_for(
          Fixtures.Users.create_user(),
          Fixtures.Accounts.create_account(),
          role: :owner
        )

      user_a = Fixtures.Users.create_user()
      _ = Fixtures.Memberships.create_membership(account_id: account_a.id, user_id: user_a.id)

      {:ok, _} =
        Audit.log(account_a.id, "user.invited", target_kind: "user", target_id: user_a.id)

      assert {:ok, []} = Audit.list_target_options("user", subject_b)
    end

    # (context half) — `policy` and `approval_grant` have no
    # label resolver in resolve_labels/2, so every distinct id resolves to a nil
    # label and is dropped → the picker has zero options (intentional).
    test "a resolver-less subject kind yields no options" do
      account = Fixtures.Accounts.create_account()
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)

      {:ok, _} =
        Audit.log(account.id, "policy.updated",
          target_kind: "policy",
          target_id: Ecto.UUID.generate()
        )

      assert {:ok, []} = Audit.list_target_options("policy", subject)
      assert {:ok, []} = Audit.list_target_options("approval_grant", subject)
    end

    # a subject id that WAS resolvable when the event was
    # written but whose row has since gone unresolvable resolves to a nil label
    # and is rejected, so the picker doesn't offer a dead option. Here the user's
    # membership is removed after the event, so the user-label resolver (scoped
    # through `members_of_account`) no longer finds them in the account.
    test "a subject whose label can no longer resolve is dropped from the options" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: owner.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      member = Fixtures.Users.create_user(email: "departing@example.com")

      membership =
        Fixtures.Memberships.create_membership(account_id: account.id, user_id: member.id)

      {:ok, _} =
        Audit.log(account.id, "user.invited", target_kind: "user", target_id: member.id)

      # While the member is in the account, the picker offers them.
      assert {:ok, [{id, "departing@example.com"}]} =
               Audit.list_target_options("user", subject)

      assert id == member.id

      # Remove the membership — the audit row still references the user id, but
      # the label resolver (members_of_account) can no longer resolve it, so the
      # option is dropped rather than rendered with a nil/blank label.
      membership
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
      |> Repo.update!()

      assert {:ok, []} = Audit.list_target_options("user", subject)
    end
  end

  describe "list_for_export/2 (SIEM forward sweep)" do
    defp seed_export_events(account, count) do
      base = DateTime.add(DateTime.utc_now(), -3600, :second)

      for offset <- 1..count do
        {:ok, event} =
          Audit.log(account.id, "user.signed_in",
            actor_kind: "user",
            occurred_at: DateTime.add(base, offset, :second)
          )

        event
      end
    end

    setup do
      account = Fixtures.Accounts.create_account()
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)
      %{account: account, subject: subject}
    end

    test "returns ascending (occurred_at, id) so SIEMs can checkpoint", %{
      account: account,
      subject: subject
    } do
      [first, second, third] = seed_export_events(account, 3)

      assert {:ok, events} = Audit.list_for_export(subject)
      assert Enum.map(events, & &1.id) == [first.id, second.id, third.id]
    end

    test ":after cursor is strict — resuming never re-ingests the checkpoint row", %{
      account: account,
      subject: subject
    } do
      [first, second, third] = seed_export_events(account, 3)

      assert {:ok, [event_a, event_b]} =
               Audit.list_for_export(subject, after: {first.occurred_at, first.id})

      assert event_a.id == second.id
      assert event_b.id == third.id
    end

    test ":since is an inclusive lower bound and :limit caps the page", %{
      account: account,
      subject: subject
    } do
      [_first, second, third] = seed_export_events(account, 3)

      assert {:ok, [only]} =
               Audit.list_for_export(subject, since: second.occurred_at, limit: 1)

      assert only.id == second.id
      _ = third
    end

    test ":event_types narrows the sweep", %{account: account, subject: subject} do
      _ = seed_export_events(account, 2)
      {:ok, denied} = Audit.log(account.id, "approval.denied", actor_kind: "user")

      assert {:ok, [only]} = Audit.list_for_export(subject, event_types: ["approval.denied"])
      assert only.id == denied.id
    end

    test "a junk :limit falls back to the default; the cap is exposed for the controller", %{
      account: account,
      subject: subject
    } do
      _ = seed_export_events(account, 2)

      assert {:ok, [_, _]} = Audit.list_for_export(subject, limit: "junk")
      assert Audit.max_export_limit() == 1_000
      assert Audit.default_export_limit() == 100
    end

    test "an owner of account B never exports account A's events (cross-account)" do
      account_a = Fixtures.Accounts.create_account()
      _ = seed_export_events(account_a, 2)

      subject_b =
        Fixtures.Subjects.subject_for(
          Fixtures.Users.create_user(),
          Fixtures.Accounts.create_account(),
          role: :owner
        )

      assert {:ok, []} = Audit.list_for_export(subject_b)
    end

    # a subject whose role carries no `view_audit` is
    # rejected from INSIDE list_for_export with {:error, :unauthorized} (the
    # controller turns that into a 403), never a 500 or a leaked export. The
    # runner (websocket) role is the no-`view_audit` role; an API-key role DOES
    # carry it and is gated by per-key scope at the controller instead.
    test "a no-view_audit role is denied, not a 500" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = seed_export_events(account, 2)

      runner_subject = Subject.for_runner(runner, account)

      assert {:error, :unauthorized} = Audit.list_for_export(runner_subject)
    end
  end

  describe "record_export/3" do
    test "count > 0 records one audit.exported attributed to the exporter, with the count" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()

      assert {:ok, event} = Audit.record_export(subject, [limit: 100, event_types: []], 7)
      assert event.event_type == "audit.exported"
      assert event.account_id == account.id
      assert event.actor_id == subject.actor.id

      # Re-read: JSONB round-trips the payload's keys to strings.
      {:ok, events, _} = Audit.list_events(subject, page: [limit: 50])
      assert [marker] = Enum.filter(events, &(&1.event_type == "audit.exported"))
      assert marker.payload["count"] == 7
    end

    test "count == 0 records nothing — a caught-up poll leaves no marker" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()

      assert {:ok, :not_recorded} = Audit.record_export(subject, [limit: 100], 0)

      {:ok, events, _} = Audit.list_events(subject, page: [limit: 50])
      refute Enum.any?(events, &(&1.event_type == "audit.exported"))
    end
  end

  describe "max_export_limit/0" do
    test "is a positive row ceiling the export sweep clamps an oversized limit to" do
      assert is_integer(Audit.max_export_limit())
      assert Audit.max_export_limit() == 1_000
    end
  end

  describe "default_export_limit/0" do
    test "is the fallback page size, and never exceeds the hard ceiling" do
      assert Audit.default_export_limit() == 100
      assert Audit.default_export_limit() <= Audit.max_export_limit()
    end
  end

  describe "fetch_event_by_id/2" do
    test "returns the event inside the subject's account" do
      account = Fixtures.Accounts.create_account()
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)
      {:ok, event} = Audit.log(account.id, "user.signed_in", actor_kind: "user")

      assert {:ok, fetched} = Audit.fetch_event_by_id(event.id, subject)
      assert fetched.id == event.id
    end

    test "an owner of account B cannot fetch account A's event (cross-account → :not_found)" do
      account_a = Fixtures.Accounts.create_account()
      {:ok, event_a} = Audit.log(account_a.id, "user.signed_in", actor_kind: "user")

      subject_b =
        Fixtures.Subjects.subject_for(
          Fixtures.Users.create_user(),
          Fixtures.Accounts.create_account(),
          role: :owner
        )

      assert {:error, :not_found} = Audit.fetch_event_by_id(event_a.id, subject_b)
    end

    test "a malformed id is a clean :not_found" do
      subject =
        Fixtures.Subjects.subject_for(
          Fixtures.Users.create_user(),
          Fixtures.Accounts.create_account(),
          role: :owner
        )

      assert {:error, :not_found} = Audit.fetch_event_by_id("not-a-uuid", subject)
    end
  end

  describe "resolve_references/1" do
    setup do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "owner"
        )

      %{account: account, user: user}
    end

    test "returns live labels for users, runners, and api keys", %{account: account, user: user} do
      # User labels scope through membership — the setup stamped the owner
      # membership the real write path would have created. Owner role so
      # Fixtures.ApiKeys.create_api_key's owner-subject can mint
      # (Fixtures.Subjects.subject_for reads the persisted membership role).
      runner = Fixtures.Runners.create_runner(account_id: account.id, name: "db-prod-01")

      {_raw, api_key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)

      {:ok, e_user} =
        Audit.log(account.id, "user.touched",
          actor_kind: "user",
          actor_id: user.id,
          target_kind: "user",
          target_id: user.id
        )

      {:ok, e_runner} =
        Audit.log(account.id, "runner.touched",
          target_kind: "runner",
          target_id: runner.id
        )

      {:ok, e_key} =
        Audit.log(account.id, "api_key.touched",
          target_kind: "api_key",
          target_id: api_key.id
        )

      refs = Audit.resolve_references([e_user, e_runner, e_key])

      assert refs["user"][user.id] == user.email
      assert refs["runner"][runner.id] == "db-prod-01"
      assert refs["api_key"][api_key.id] == api_key.name
    end

    test "missing records (deleted since the event) are simply absent" do
      account = Fixtures.Accounts.create_account()
      ghost_id = Ecto.UUID.generate()

      {:ok, event} =
        Audit.log(account.id, "user.gone",
          actor_kind: "user",
          actor_id: ghost_id
        )

      refs = Audit.resolve_references([event])

      refute Map.has_key?(refs["user"], ghost_id)
    end

    test "an id stamped from another account does not resolve (account-scoped)" do
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()

      # A runner + user that genuinely live in account B.
      runner_b = Fixtures.Runners.create_runner(account_id: account_b.id, name: "b-runner")
      user_b = Fixtures.Users.create_user()
      _ = Fixtures.Memberships.create_membership(account_id: account_b.id, user_id: user_b.id)

      # A mis-stamped audit row in account A pointing at B's ids.
      {:ok, event} =
        Audit.log(account_a.id, "cross.account",
          actor_kind: "user",
          actor_id: user_b.id,
          target_kind: "runner",
          target_id: runner_b.id
        )

      refs = Audit.resolve_references([event])

      refute Map.has_key?(refs["user"], user_b.id)
      refute Map.has_key?(refs["runner"], runner_b.id)
    end

    test "resolves enrollment_key, action_run, approval_request, and runbook labels", %{
      account: account,
      user: user
    } do
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      {_raw, enrollment_key} =
        Fixtures.Runners.create_enrollment_key(
          account_id: account.id,
          created_by_id: user.id,
          description: "enroll-prod"
        )

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "operator",
          args: %{}
        })

      {:ok, request} = Approvals.create_request(run, user.id, "needs approval")

      {:ok, runbook} =
        Runbooks.create_runbook(
          %{
            "title" => "deploy-book",
            "name" => "deploy-book",
            "slug" => "deploy-book",
            "definition" => %{
              "steps" => [%{"id" => "s1", "action_id" => "linux.uptime", "args" => %{}}]
            }
          },
          subject
        )

      {:ok, e_enrollment_key} =
        Audit.log(account.id, "enrollment_key.touched",
          target_kind: "enrollment_key",
          target_id: enrollment_key.id
        )

      {:ok, e_run} =
        Audit.log(account.id, "run.touched", target_kind: "action_run", target_id: run.id)

      {:ok, e_request} =
        Audit.log(account.id, "approval.touched",
          target_kind: "approval_request",
          target_id: request.id
        )

      {:ok, e_runbook} =
        Audit.log(account.id, "runbook.touched", target_kind: "runbook", target_id: runbook.id)

      refs = Audit.resolve_references([e_enrollment_key, e_run, e_request, e_runbook])

      assert refs["enrollment_key"][enrollment_key.id] == "enroll-prod"
      assert refs["action_run"][run.id] == "linux.uptime"
      # The approval_request resolver labels by id (no friendlier handle exists).
      assert refs["approval_request"][request.id] == request.id
      assert refs["runbook"][runbook.id] == "deploy-book"
    end
  end

  describe "Event.Query.outcome/1 (one source for the dots + the Outcome filter)" do
    test "failures and errors are :danger" do
      for t <- ~w[user.sign_in_failed user.mfa_failed
                  action_run.failed action_run.error runner.error action_run.timed_out] do
        assert Audit.Event.Query.outcome(t) == :danger, "expected #{t} to be :danger"
      end
    end

    test "denials and access taken away are :warn" do
      for t <- ~w[approval.denied action_run.denied enrollment_key.revoked user.session_revoked
                  runner.disabled runner.deleted membership.removed membership.suspended
                  approval.expired action_run.cancelled approval.grant_revoked] do
        assert Audit.Event.Query.outcome(t) == :warn, "expected #{t} to be :warn"
      end
    end

    test "pass verdicts — the gate saying yes — are :pass" do
      for t <- ~w[action_run.success approval.approved approval.grant_used
                  sso.link_request_approved oauth.consent_granted] do
        assert Audit.Event.Query.outcome(t) == :pass, "expected #{t} to be :pass"
      end
    end

    test "lifecycle positives stay :neutral — green marks verdicts, not activity" do
      for t <- ~w[api_key.created runner.connected runner.enabled user.signed_in
                  user.email_confirmed user.mfa_enabled membership.invitation_accepted
                  membership.reinstated runbook.published session.account_switched] do
        assert Audit.Event.Query.outcome(t) == :neutral, "expected #{t} to be :neutral"
      end
    end

    test "nil and non-binary fall back to :neutral" do
      assert Audit.Event.Query.outcome(nil) == :neutral
      assert Audit.Event.Query.outcome(42) == :neutral
    end

    # the row dot tone (web) and the "Outcome" filter both
    # read the SAME outcome/1 classifier, so they can never disagree. Drive the
    # filter end-to-end through list_events: log one known type of each tone and
    # assert the filter keeps exactly the rows outcome/1 calls danger/warn — i.e.
    # the filter genuinely resolves through outcome/1, not a parallel copy.
    test "the Outcome filter narrows to exactly the rows outcome/1 classifies" do
      account = Fixtures.Accounts.create_account()
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)

      # Real known types, one per tone (outcome/1: danger / warn / pass / neutral).
      {:ok, _} = Audit.log(account.id, "action_run.failed", actor_kind: "system")
      {:ok, _} = Audit.log(account.id, "approval.denied", actor_kind: "user")
      {:ok, _} = Audit.log(account.id, "approval.approved", actor_kind: "user")
      {:ok, _} = Audit.log(account.id, "runner.connected", actor_kind: "runner")

      assert Audit.Event.Query.outcome("action_run.failed") == :danger
      assert Audit.Event.Query.outcome("approval.denied") == :warn
      assert Audit.Event.Query.outcome("approval.approved") == :pass
      assert Audit.Event.Query.outcome("runner.connected") == :neutral

      {:ok, danger, _} = Audit.list_events(subject, filter: [outcome: ["danger"]])
      assert Enum.map(danger, & &1.event_type) == ["action_run.failed"]

      {:ok, both, _} = Audit.list_events(subject, filter: [outcome: ["danger", "warn"]])

      assert Enum.sort(Enum.map(both, & &1.event_type)) ==
               ["action_run.failed", "approval.denied"]
    end
  end

  describe "the event taxonomy (known types, kinds, noisy set, builders)" do
    # the Actor-type dropdown exposes exactly the six actor
    # kinds and the Target filter the nine target kinds the catalog enumerates;
    # both lists are read straight from the LiveTable %Filter{} values so a
    # silently-added/dropped kind is caught.
    test "the actor-kind and subject-kind filter enumerations match the catalog" do
      assert filter_values(:actor_kind) ==
               ~w[user api_key runner runbook scheduler system]

      assert filter_values(:target_kind) ==
               ~w[user account runner api_key enrollment_key approval_request
                  approval_grant runbook policy]
    end

    # `runbook.dispatched` is a first-class audit type: it appears in both
    # dropdowns and has a builder, so filtering by it can return real rows.
    test "runbook.dispatched is declared and emitted by a builder" do
      known = Audit.Event.Query.known_event_type_values() |> Enum.map(&elem(&1, 0))

      grouped =
        Audit.Event.Query.grouped_event_type_values()
        |> Enum.flat_map(fn {_group, items} -> Enum.map(items, &elem(&1, 0)) end)

      assert "runbook.dispatched" in known
      assert "runbook.dispatched" in grouped

      emitted = emitted_event_types()
      assert "runbook.created" in emitted
      assert "runbook.published" in emitted
      assert "runbook.dispatched" in emitted
    end
  end

  describe "builder-vs-known event-type drift" do
    # several types are EMITTED by a builder but are NOT in
    # `known_event_type_values/0` / `grouped_event_type_values/0`, so they render
    # + humanize + pass filters, yet can't be picked from the Type dropdown. We
    # ground both halves in source: the emitted set (every literal a builder
    # passes) and the dropdown set. If a drift type is later added to the
    # dropdown, this fails loudly — which is correct (it closed the gap then).
    test "builder-only types are emitted but absent from the Type dropdown" do
      # account.require_sso_set was promoted INTO the dropdown alongside
      # require_mfa_set (the account-security toggles filter as a set), so it's no
      # longer drift.
      drift = ~w[
        user.mfa_reset_by_admin policy.scope_deleted
        approval.decision_recorded sso.provider_configured sso.provider_updated
        sso.provider_deleted sso.existing_user_linked
      ]

      emitted = emitted_event_types()
      known = Audit.Event.Query.known_event_type_values() |> Enum.map(&elem(&1, 0))

      grouped =
        Audit.Event.Query.grouped_event_type_values()
        |> Enum.flat_map(fn {_group, items} -> Enum.map(items, &elem(&1, 0)) end)

      for type <- drift do
        # A real builder produces it…
        assert type in emitted, "#{type} expected to be emitted by a builder"
        # …but it isn't selectable from either the flat or grouped dropdown.
        refute type in known, "#{type} unexpectedly IN known_event_type_values/0"
        refute type in grouped, "#{type} unexpectedly IN grouped_event_type_values/0"
      end
    end

    # (humanization half) — a drift type still renders a
    # human label via format_event_type/1's fallback humanizer, so a row of one
    # isn't a blank/raw machine code even though the dropdown can't offer it.
    test "a drift type still humanizes for the row label" do
      # format_event_type lives in the web app; assert the humanization contract
      # the dropdown-absent types rely on the same way the web test does, here
      # via the known-list lookup miss → title-cased fallback.
      refute "user.mfa_reset_by_admin" in (Audit.Event.Query.known_event_type_values()
                                           |> Enum.map(&elem(&1, 0)))
    end
  end

  describe "directory_sync is a distinct actor class" do
    # an inbound-SCIM event stamps the actor as
    # `directory_sync` + the provider id (so an auditor sees WHICH directory
    # acted), not a generic `system`. Build a struct-literal provider scoped to a
    # real account and run it through the real builder → changeset → insert.
    test "a SCIM-provisioned user event carries directory_sync + the provider id" do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      provider = %SSO.IdentityProvider{
        id: Repo.generate_id(),
        account_id: account.id,
        name: "Okta (prod)",
        kind: :okta,
        default_role: :viewer
      }

      {:ok, event} = Audit.record(Audit.Events.user_provisioned_via_scim(user, provider))

      assert event.event_type == "user.provisioned_via_scim"
      # The directory connection is the actor — provider id + name, not "system".
      assert event.actor_kind == "directory_sync"
      assert event.actor_id == provider.id
      assert event.actor_label == "Okta (prod)"
      refute event.actor_kind == "system"
      # Fresh insert returns atom-keyed payload (JSON string-keying is a reload
      # concern) — same convention as the run_event_changeset test above.
      assert event.payload[:provider_id] == provider.id
    end

    # (taxonomy half) — `directory_sync` is deliberately NOT
    # one of the six Actor-type dropdown values (you filter SCIM events by Type),
    # so it can't be collapsed into `system` by the picker either.
    test "directory_sync is not an Actor-type filter value" do
      refute "directory_sync" in filter_values(:actor_kind)
      # The builders really do stamp it (grounds "distinct class" in source).
      assert "directory_sync" in emitted_event_types()
    end
  end

  describe "non-terminal run states are not audited" do
    # driving a run through its NON-terminal lifecycle
    # (pending → sent → running) writes ZERO audit rows: only terminal outcomes
    # + policy denials leave a row (`Runs.@audited_run_statuses`). The
    # pending/sent/running labels exist in the known list for the Type dropdown
    # only — they match no real audit row.
    test "pending → sent → running produces no audit_event rows" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      before = Repo.aggregate(Audit.Event, :count, :id)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "operator",
          args: %{}
        })

      assert run.status == :pending
      {:ok, sent} = Runs.mark_sent(run)
      assert sent.status == :sent
      {:ok, running} = Runs.mark_running(sent)
      assert running.status == :running

      assert Repo.aggregate(Audit.Event, :count, :id) == before
    end
  end

  describe "the audit log is append-only by construction" do
    # "tamper-evident" here means there is NO
    # public API path that mutates or deletes a recorded event: the Audit context
    # exposes only inserts/reads (log / record / changeset / *_changeset / list_* /
    # fetch_* / resolve_references), and the Event.Changeset module exposes only
    # `create/1` — no update/delete transition. The single deletion path is the
    # retention sweep (Workers.AuditRetention), by cutoff, never per-event. This
    # is a real surface assertion, not a vacuous one: a future `Audit.update_event`
    # or an `Event.Changeset.update` would fail this immediately.
    test "the Audit context exposes no update/delete-an-event function" do
      audit_fns = Emisar.Audit.__info__(:functions) |> Keyword.keys() |> Enum.map(&to_string/1)

      # Every public read/write is an insert or a read — none of these mutate or
      # remove an existing row.
      forbidden_substrings = ~w[update delete destroy edit modify remove]

      offending =
        Enum.filter(audit_fns, fn name ->
          Enum.any?(forbidden_substrings, &String.contains?(name, &1))
        end)

      assert offending == [],
             "Audit must expose no event-mutation function; found: #{inspect(offending)}"
    end

    test "the Event.Changeset module exposes only create/1 — no update or delete transition" do
      transitions =
        Emisar.Audit.Event.Changeset.__info__(:functions)
        |> Keyword.keys()
        |> Enum.map(&to_string/1)

      assert "create" in transitions
      refute "update" in transitions
      refute "delete" in transitions
    end

    # the accepted trade-off (NOT a defect): the cloud audit
    # log is append-only by construction but carries NO cryptographic hash chain
    # (the runner-side chain is the RSEC anchor). Asserting the documented design,
    # not a missing feature.
    test "the schema carries no prev_hash / signature / anchor chain column" do
      # Append-only-by-construction, NOT cryptographic: there is intentionally no
      # hash-chain or signature on the row (so the test asserts the documented
      # design, not an absent feature we should add).
      fields = Emisar.Audit.Event.__schema__(:fields) |> Enum.map(&to_string/1)

      for chain_field <- ~w[prev_hash previous_hash signature anchor chain_hash] do
        refute chain_field in fields
      end
    end
  end

  # -- Taxonomy helpers ------------------------------------------------

  # The %Filter{} value codes for a static filter (e.g. actor_kind / target_kind
  # enumerations) — read from the query module's own filters/0 so the assertion
  # tracks the real dropdown, not a hand-copied list.
  defp filter_values(name) do
    Audit.Event.Query.filters()
    |> Enum.find(&(&1.name == name))
    |> Map.fetch!(:values)
    |> Enum.map(&elem(&1, 0))
  end

  # Every event_type string literal a builder passes to `Audit.changeset/3`,
  # read from the Audit.Events source. Grounds builder-vs-dropdown assertions in
  # actual builder code instead of hand-copied event lists.
  defp emitted_event_types do
    path = Path.join(File.cwd!(), "lib/emisar/audit/events.ex")

    ~r/"([a-z_]+(?:\.[a-z_]+)?)"/
    |> Regex.scan(File.read!(path), capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  describe "subject_can_view_audit?/1" do
    test "true for a viewer, false for a billing_manager (the nav gate)" do
      account = Fixtures.Accounts.create_account()

      viewer_subject =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :viewer)

      billing_manager_subject =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account,
          role: :billing_manager
        )

      assert Audit.subject_can_view_audit?(viewer_subject)
      refute Audit.subject_can_view_audit?(billing_manager_subject)
    end
  end
end
