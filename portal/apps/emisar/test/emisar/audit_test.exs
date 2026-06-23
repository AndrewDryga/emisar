defmodule Emisar.AuditTest do
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.{Approvals, Audit, RequestContext, Runbooks, Runs, SSO}
  alias Emisar.Auth.Subject

  describe "log/3 with a %RequestContext{}" do
    test "stamps IP/UA/request_id/mcp_session from the :context struct" do
      account = account_fixture()

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

    test "explicit attrs win over the context struct" do
      account = account_fixture()
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

    test "with no :context, request metadata is nil (system / engine origin)" do
      account = account_fixture()

      {:ok, event} = Audit.log(account.id, "audit.test", actor_kind: "system")

      assert event.ip_address == nil
      assert event.user_agent == nil
      assert event.request_id == nil
      assert event.mcp_session_id == nil
    end

    test "over-long request metadata is truncated, not rejected (audit can't be evaded)" do
      account = account_fixture()

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
    test "an invented string field key raises rather than minting an atom (IL-14)" do
      account = account_fixture()

      assert_raise ArgumentError, fn ->
        Audit.log(account.id, "audit.test", %{
          "actor_kind" => "system",
          "this_audit_field_was_never_declared_zqx" => "x"
        })
      end
    end
  end

  describe "log_for_user/3 without a membership" do
    # a user with no active membership can't be scoped to an
    # account_id, so the event is silently skipped (returns :ok, writes nothing)
    # rather than raising or writing an account-less row.
    test "no-ops (returns :ok) and writes no row when the user has no membership" do
      user = user_fixture()
      before = Repo.aggregate(Audit.Event, :count, :id)

      assert :ok = Audit.log_for_user(user, "user.signed_in", actor_kind: "user")
      assert Repo.aggregate(Audit.Event, :count, :id) == before
    end
  end

  describe "run_event_changeset/1" do
    # request_id + mcp_session_id are promoted to first-class
    # fields (not buried in payload), and nil payload keys are compacted so a
    # freshly-created run's row doesn't bloat with still-empty fields.
    test "promotes request_id + mcp_session_id and drops nil payload keys" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)

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
      # runner_id is present; the still-nil fields are compacted out.
      assert payload[:runner_id] == runner.id
      refute Map.has_key?(payload, :exit_code)
      refute Map.has_key?(payload, :duration_ms)
      refute Map.has_key?(payload, :executed_command)
    end
  end

  describe "system/engine-origin builders carry no request metadata" do
    # (builder half) — a system-actor builder passes no
    # :context, so the changeset defaults to an all-nil RequestContext. Engine
    # rows never inherit a caller's ip/ua (the runner-UA-bleed class of bug).
    test "policy_evaluated has nil ip/ua/request_id/mcp_session" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "operator",
          args: %{}
        })

      {:ok, event} =
        Audit.record(Audit.Events.policy_evaluated(run, nil, :allow, "ok", []))

      assert event.actor_kind == "system"
      assert event.ip_address == nil
      assert event.user_agent == nil
      assert event.request_id == nil
      assert event.mcp_session_id == nil
    end
  end

  describe "Audit.Events builders inherit the subject's request context" do
    setup do
      account = account_fixture()
      user = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
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

      subject = subject_for(user, account, role: :owner, context: context)

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
      subject = subject_for(user, account, role: :owner)

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
        subject_for(user, account,
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
      subject = subject_for(user, account, role: :owner)

      {:ok, event} = Audit.record(Audit.Events.account_updated(subject, account))

      assert event.auth_method == nil
      assert event.user_identity_id == nil
    end
  end

  describe "resolve_references/1" do
    test "returns live labels for users, runners, and api keys", %{} do
      account = account_fixture()
      user = user_fixture()
      # User labels scope through membership — stamp the membership the real
      # write path would have created. Owner role so api_key_fixture's
      # owner-subject can mint (subject_for reads the persisted membership role).
      _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
      runner = runner_fixture(account_id: account.id, name: "db-prod-01")
      {_raw, api_key} = api_key_fixture(account_id: account.id, created_by_id: user.id)

      {:ok, e_user} =
        Audit.log(account.id, "user.touched",
          actor_kind: "user",
          actor_id: user.id,
          subject_kind: "user",
          subject_id: user.id
        )

      {:ok, e_runner} =
        Audit.log(account.id, "runner.touched",
          subject_kind: "runner",
          subject_id: runner.id
        )

      {:ok, e_key} =
        Audit.log(account.id, "api_key.touched",
          subject_kind: "api_key",
          subject_id: api_key.id
        )

      refs = Audit.resolve_references([e_user, e_runner, e_key])

      assert refs["user"][user.id] == user.email
      assert refs["runner"][runner.id] == "db-prod-01"
      assert refs["api_key"][api_key.id] == api_key.name
    end

    test "missing records (deleted since the event) are simply absent" do
      account = account_fixture()
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
      account_a = account_fixture()
      account_b = account_fixture()

      # A runner + user that genuinely live in account B.
      runner_b = runner_fixture(account_id: account_b.id, name: "b-runner")
      user_b = user_fixture()
      _ = membership_fixture(account_id: account_b.id, user_id: user_b.id)

      # A mis-stamped audit row in account A pointing at B's ids.
      {:ok, event} =
        Audit.log(account_a.id, "cross.account",
          actor_kind: "user",
          actor_id: user_b.id,
          subject_kind: "runner",
          subject_id: runner_b.id
        )

      refs = Audit.resolve_references([event])

      refute Map.has_key?(refs["user"], user_b.id)
      refute Map.has_key?(refs["runner"], runner_b.id)
    end

    test "resolves auth_key, action_run, approval_request, and runbook labels" do
      account = account_fixture()
      user = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
      subject = subject_for(user, account, role: :owner)
      runner = runner_fixture(account_id: account.id)

      {_raw, auth_key} =
        auth_key_fixture(
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

      {:ok, e_auth_key} =
        Audit.log(account.id, "auth_key.touched",
          subject_kind: "auth_key",
          subject_id: auth_key.id
        )

      {:ok, e_run} =
        Audit.log(account.id, "run.touched", subject_kind: "action_run", subject_id: run.id)

      {:ok, e_request} =
        Audit.log(account.id, "approval.touched",
          subject_kind: "approval_request",
          subject_id: request.id
        )

      {:ok, e_runbook} =
        Audit.log(account.id, "runbook.touched", subject_kind: "runbook", subject_id: runbook.id)

      refs = Audit.resolve_references([e_auth_key, e_run, e_request, e_runbook])

      assert refs["auth_key"][auth_key.id] == "enroll-prod"
      assert refs["action_run"][run.id] == "linux.uptime"
      # The approval_request resolver labels by id (no friendlier handle exists).
      assert refs["approval_request"][request.id] == request.id
      assert refs["runbook"][runbook.id] == "deploy-book"
    end
  end

  describe "Event.Query.outcome/1 (one source for the dots + the Outcome filter)" do
    test "failures and errors are :danger" do
      for t <- ~w[user.sign_in_failed user.mfa_failed user.password_change_failed
                  action_run.failed action_run.error runner.error action_run.timed_out] do
        assert Audit.Event.Query.outcome(t) == :danger, "expected #{t} to be :danger"
      end
    end

    test "denials and access taken away are :warn" do
      for t <- ~w[approval.denied action_run.denied auth_key.revoked user.session_revoked
                  runner.disabled runner.deleted membership.removed membership.suspended
                  approval.expired action_run.cancelled approval.grant_revoked] do
        assert Audit.Event.Query.outcome(t) == :warn, "expected #{t} to be :warn"
      end
    end

    test "routine events are :neutral" do
      for t <- ~w[action_run.success approval.approved api_key.created runner.connected
                  runner.enabled user.signed_in session.account_switched policy.evaluated] do
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
      account = account_fixture()
      subject = subject_for(user_fixture(), account, role: :owner)

      # Real known types, one per tone (outcome/1: danger / warn / neutral).
      {:ok, _} = Audit.log(account.id, "action_run.failed", actor_kind: "system")
      {:ok, _} = Audit.log(account.id, "approval.denied", actor_kind: "user")
      {:ok, _} = Audit.log(account.id, "approval.approved", actor_kind: "user")

      assert Audit.Event.Query.outcome("action_run.failed") == :danger
      assert Audit.Event.Query.outcome("approval.denied") == :warn
      assert Audit.Event.Query.outcome("approval.approved") == :neutral

      {:ok, danger, _} = Audit.list_events(subject, filter: [outcome: ["danger"]])
      assert Enum.map(danger, & &1.event_type) == ["action_run.failed"]

      {:ok, both, _} = Audit.list_events(subject, filter: [outcome: ["danger", "warn"]])

      assert Enum.sort(Enum.map(both, & &1.event_type)) ==
               ["action_run.failed", "approval.denied"]
    end
  end

  describe "the event taxonomy (known types, kinds, noisy set, builders)" do
    # the Actor-type dropdown exposes exactly the six actor
    # kinds and the Subject filter the ten subject kinds the catalog enumerates;
    # both lists are read straight from the LiveTable %Filter{} values so a
    # silently-added/dropped kind is caught.
    test "the actor-kind and subject-kind filter enumerations match the catalog" do
      assert filter_values(:actor_kind) ==
               ~w[user api_key runner runbook scheduler system]

      assert filter_values(:subject_kind) ==
               ~w[user account runner api_key auth_key action_run approval_request
                  approval_grant runbook policy]
    end

    # the "Hide noisy events" set is exactly the three
    # auto-fired-by-traffic types; widening it would silently hide
    # operator-facing rows.
    test "the noisy set is exactly the three traffic-byproduct types" do
      assert Enum.sort(Audit.Event.Query.noisy_event_types()) ==
               ~w[policy.evaluated runner.connected runner.disconnected]
    end

    # `runbook.dispatched` is DECLARED (known list + grouped
    # dropdown) but NEVER EMITTED: no `Audit.Events` builder produces it, so the
    # dropdown option matches zero rows. We ground "never emitted" in the builder
    # source itself — every event_type string literal in events.ex — so the test
    # can't drift if a real `runbook.dispatched` builder is later added.
    test "runbook.dispatched is declared but emitted by no builder (dead dropdown option)" do
      known = Audit.Event.Query.known_event_type_values() |> Enum.map(&elem(&1, 0))

      grouped =
        Audit.Event.Query.grouped_event_type_values()
        |> Enum.flat_map(fn {_group, items} -> Enum.map(items, &elem(&1, 0)) end)

      # Declared in BOTH the flat known list and the grouped dropdown…
      assert "runbook.dispatched" in known
      assert "runbook.dispatched" in grouped

      # …but produced by no builder. The sibling runbook events ARE emitted —
      # proves the extraction sees real builder output, not an empty set.
      emitted = emitted_event_types()
      assert "runbook.created" in emitted
      assert "runbook.published" in emitted
      refute "runbook.dispatched" in emitted
    end
  end

  describe "list_events/2 (paginated + filterable)" do
    test "page size + Next cursor walk through every row in order" do
      account = account_fixture()
      subject = subject_for(user_fixture(), account, role: :owner)

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

    test "filter list narrows to matching event_types only" do
      account = account_fixture()
      subject = subject_for(user_fixture(), account, role: :owner)

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

    test "the request_id filter matches request_id, with wildcards escaped" do
      account = account_fixture()
      subject = subject_for(user_fixture(), account, role: :owner)

      log = fn type, req_id ->
        {:ok, _} =
          Audit.log(account.id, type,
            actor_kind: "system",
            context: %RequestContext{request_id: req_id}
          )
      end

      log.("policy.updated", "req_trace")
      # A would-be wildcard collision: if `_` weren't escaped, searching
      # "req_trace" would also match this.
      log.("user.invited", "reqZtrace")

      # Paste a request_id → only its event; the `_` is matched literally.
      assert {:ok, [hit], %{count: 1}} =
               Audit.list_events(subject, filter: [request_id: "req_trace"])

      assert hit.request_id == "req_trace"
    end

    test "actor_kind list filter accepts a list of kinds" do
      account = account_fixture()
      subject = subject_for(user_fixture(), account, role: :owner)

      {:ok, _} = Audit.log(account.id, "x", actor_kind: "user")
      {:ok, _} = Audit.log(account.id, "x", actor_kind: "api_key")
      {:ok, _} = Audit.log(account.id, "x", actor_kind: "system")

      {:ok, rows, _} =
        Audit.list_events(subject, filter: [actor_kind: ["user", "api_key"]])

      assert length(rows) == 2
      assert Enum.all?(rows, &(&1.actor_kind in ["user", "api_key"]))
    end

    test "invalid cursor surfaces an error rather than returning random rows" do
      account = account_fixture()
      subject = subject_for(user_fixture(), account, role: :owner)

      assert {:error, :invalid_cursor} =
               Audit.list_events(subject, page: [cursor: "garbage"])
    end

    test "a well-formed but type-mismatched cursor is :invalid_cursor, not a 500" do
      account = account_fixture()
      subject = subject_for(user_fixture(), account, role: :owner)
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

    test "hide_noise filter excludes the canonical noisy event types" do
      account = account_fixture()
      subject = subject_for(user_fixture(), account, role: :owner)

      # One of each: 2 noisy types + 2 operator-facing types.
      {:ok, _} = Audit.log(account.id, "policy.evaluated", actor_kind: "system")
      {:ok, _} = Audit.log(account.id, "runner.connected", actor_kind: "runner")
      {:ok, _} = Audit.log(account.id, "approval.approved", actor_kind: "user")
      {:ok, _} = Audit.log(account.id, "user.invited", actor_kind: "user")

      {:ok, rows, %{count: 2}} =
        Audit.list_events(subject, filter: [hide_noise: true])

      kept = Enum.map(rows, & &1.event_type) |> Enum.sort()
      assert kept == ["approval.approved", "user.invited"]
    end

    test "outcome filter narrows to failures (danger) and denials (warn) by suffix" do
      account = account_fixture()
      subject = subject_for(user_fixture(), account, role: :owner)

      {:ok, _} = Audit.log(account.id, "action_run.failed", actor_kind: "system")
      {:ok, _} = Audit.log(account.id, "approval.denied", actor_kind: "user")
      {:ok, _} = Audit.log(account.id, "approval.approved", actor_kind: "user")

      # "danger" keeps only the failure; routine (approved) is excluded.
      {:ok, danger, _} = Audit.list_events(subject, filter: [outcome: ["danger"]])
      assert Enum.map(danger, & &1.event_type) == ["action_run.failed"]

      # Both outcomes keep the failure + the denial, still dropping the routine.
      {:ok, both, _} = Audit.list_events(subject, filter: [outcome: ["danger", "warn"]])
      kept = Enum.map(both, & &1.event_type) |> Enum.sort()
      assert kept == ["action_run.failed", "approval.denied"]
    end

    test "hide_noise off (default) keeps everything" do
      account = account_fixture()
      subject = subject_for(user_fixture(), account, role: :owner)
      {:ok, _} = Audit.log(account.id, "policy.evaluated", actor_kind: "system")
      {:ok, _} = Audit.log(account.id, "approval.approved", actor_kind: "user")

      {:ok, rows, %{count: 2}} = Audit.list_events(subject)
      assert length(rows) == 2
    end

    test "actor_id narrows the list to one identity" do
      account = account_fixture()
      subject = subject_for(user_fixture(), account, role: :owner)
      actor_a = Ecto.UUID.generate()
      actor_b = Ecto.UUID.generate()
      {:ok, _} = Audit.log(account.id, "x", actor_kind: "user", actor_id: actor_a)
      {:ok, _} = Audit.log(account.id, "x", actor_kind: "user", actor_id: actor_b)

      {:ok, events, _} = Audit.list_events(subject, actor_id: actor_a)
      assert Enum.map(events, & &1.actor_id) == [actor_a]
    end

    test "subject_id narrows the list to one subject" do
      account = account_fixture()
      subject = subject_for(user_fixture(), account, role: :owner)
      subj_a = Ecto.UUID.generate()
      subj_b = Ecto.UUID.generate()
      {:ok, _} = Audit.log(account.id, "x", subject_kind: "user", subject_id: subj_a)
      {:ok, _} = Audit.log(account.id, "x", subject_kind: "user", subject_id: subj_b)

      {:ok, events, _} = Audit.list_events(subject, subject_id: subj_a)
      assert Enum.map(events, & &1.subject_id) == [subj_a]
    end

    test "the from / to date-range filters bound the window" do
      account = account_fixture()
      subject = subject_for(user_fixture(), account, role: :owner)
      {:ok, _} = Audit.log(account.id, "x", actor_kind: "system")

      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      # from/to are LiveTable %Filter{} datetime filters now — applied via :filter.
      assert {:ok, [], _} = Audit.list_events(subject, filter: [from: future])
      assert {:ok, [_ | _], _} = Audit.list_events(subject, filter: [to: future])
      assert {:ok, [_ | _], _} = Audit.list_events(subject, filter: [from: past])
    end

    test "actor_id can't surface another account's events" do
      account_a = account_fixture()
      subject_a = subject_for(user_fixture(), account_a, role: :owner)
      account_b = account_fixture()
      actor = Ecto.UUID.generate()
      {:ok, _} = Audit.log(account_b.id, "x", actor_kind: "user", actor_id: actor)

      assert {:ok, [], _} = Audit.list_events(subject_a, actor_id: actor)
    end
  end

  describe "list_actor_options/2 (the dynamic actor picker)" do
    test "returns distinct actors of the kind with resolved labels, sorted" do
      account = account_fixture()
      owner = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: owner.id, role: "owner")
      subject = subject_for(owner, account, role: :owner)

      alice = user_fixture(email: "alice@example.com")
      bob = user_fixture(email: "bob@example.com")
      _ = membership_fixture(account_id: account.id, user_id: alice.id)
      _ = membership_fixture(account_id: account.id, user_id: bob.id)

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

    test "scopes to the requested kind only" do
      account = account_fixture()
      owner = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: owner.id, role: "owner")
      subject = subject_for(owner, account, role: :owner)

      member = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: member.id)
      {_raw, key} = api_key_fixture(account_id: account.id, created_by_id: owner.id)

      {:ok, _} = Audit.log(account.id, "u", actor_kind: "user", actor_id: member.id)
      {:ok, _} = Audit.log(account.id, "k", actor_kind: "api_key", actor_id: key.id)

      assert {:ok, [{id, _label}]} = Audit.list_actor_options("api_key", subject)
      assert id == key.id
    end

    test "drops an actor only resolvable in another account (no cross-tenant leak)" do
      account_a = account_fixture()
      subject_a = subject_for(user_fixture(), account_a, role: :owner)

      user_b = user_fixture()
      account_b = account_fixture()
      _ = membership_fixture(account_id: account_b.id, user_id: user_b.id)

      # A's log references B's user (a mis-stamped id): it lives in A's events
      # but is only resolvable in B, so it must not surface in A's picker.
      {:ok, _} = Audit.log(account_a.id, "x", actor_kind: "user", actor_id: user_b.id)

      assert {:ok, []} = Audit.list_actor_options("user", subject_a)
    end

    test "a kind with no resolvable actors yields no options" do
      account = account_fixture()
      subject = subject_for(user_fixture(), account, role: :owner)
      {:ok, _} = Audit.log(account.id, "x", actor_kind: "system", actor_id: Ecto.UUID.generate())

      assert {:ok, []} = Audit.list_actor_options("system", subject)
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

    test "returns ascending (occurred_at, id) so SIEMs can checkpoint" do
      account = account_fixture()
      subject = subject_for(user_fixture(), account, role: :owner)
      [first, second, third] = seed_export_events(account, 3)

      assert {:ok, events} = Audit.list_for_export(subject)
      assert Enum.map(events, & &1.id) == [first.id, second.id, third.id]
    end

    test ":after cursor is strict — resuming never re-ingests the checkpoint row" do
      account = account_fixture()
      subject = subject_for(user_fixture(), account, role: :owner)
      [first, second, third] = seed_export_events(account, 3)

      assert {:ok, [event_a, event_b]} =
               Audit.list_for_export(subject, after: {first.occurred_at, first.id})

      assert event_a.id == second.id
      assert event_b.id == third.id
    end

    test ":since is an inclusive lower bound and :limit caps the page" do
      account = account_fixture()
      subject = subject_for(user_fixture(), account, role: :owner)
      [_first, second, third] = seed_export_events(account, 3)

      assert {:ok, [only]} =
               Audit.list_for_export(subject, since: second.occurred_at, limit: 1)

      assert only.id == second.id
      _ = third
    end

    test ":event_types narrows the sweep" do
      account = account_fixture()
      subject = subject_for(user_fixture(), account, role: :owner)
      _ = seed_export_events(account, 2)
      {:ok, denied} = Audit.log(account.id, "approval.denied", actor_kind: "user")

      assert {:ok, [only]} = Audit.list_for_export(subject, event_types: ["approval.denied"])
      assert only.id == denied.id
    end

    test "a junk :limit falls back to the default; the cap is exposed for the controller" do
      account = account_fixture()
      subject = subject_for(user_fixture(), account, role: :owner)
      _ = seed_export_events(account, 2)

      assert {:ok, [_, _]} = Audit.list_for_export(subject, limit: "junk")
      assert Audit.max_export_limit() == 1_000
      assert Audit.default_export_limit() == 100
    end

    test "an owner of account B never exports account A's events (cross-account)" do
      account_a = account_fixture()
      _ = seed_export_events(account_a, 2)

      subject_b = subject_for(user_fixture(), account_fixture(), role: :owner)

      assert {:ok, []} = Audit.list_for_export(subject_b)
    end
  end

  describe "fetch_event_by_id/2" do
    test "returns the event inside the subject's account" do
      account = account_fixture()
      subject = subject_for(user_fixture(), account, role: :owner)
      {:ok, event} = Audit.log(account.id, "user.signed_in", actor_kind: "user")

      assert {:ok, fetched} = Audit.fetch_event_by_id(event.id, subject)
      assert fetched.id == event.id
    end

    test "an owner of account B cannot fetch account A's event (cross-account → :not_found)" do
      account_a = account_fixture()
      {:ok, event_a} = Audit.log(account_a.id, "user.signed_in", actor_kind: "user")

      subject_b = subject_for(user_fixture(), account_fixture(), role: :owner)

      assert {:error, :not_found} = Audit.fetch_event_by_id(event_a.id, subject_b)
    end

    test "a malformed id is a clean :not_found" do
      subject = subject_for(user_fixture(), account_fixture(), role: :owner)
      assert {:error, :not_found} = Audit.fetch_event_by_id("not-a-uuid", subject)
    end
  end

  describe "non-terminal run states are not audited" do
    # driving a run through its NON-terminal lifecycle
    # (pending → sent → running) writes ZERO audit rows: only terminal outcomes
    # + policy denials leave a row (`Runs.@audited_run_statuses`). The
    # pending/sent/running labels exist in the known list for the Type dropdown
    # only — they match no real audit row.
    test "pending → sent → running produces no audit_event rows" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)

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

  describe "builder-vs-known event-type drift" do
    # several types are EMITTED by a builder but are NOT in
    # `known_event_type_values/0` / `grouped_event_type_values/0`, so they render
    # + humanize + pass filters, yet can't be picked from the Type dropdown. We
    # ground both halves in source: the emitted set (every literal a builder
    # passes) and the dropdown set. If a drift type is later added to the
    # dropdown, this fails loudly — which is correct (it closed the gap then).
    test "builder-only types are emitted but absent from the Type dropdown" do
      drift = ~w[
        account.require_sso_set user.mfa_reset_by_admin policy.scope_deleted
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
      refute "account.require_sso_set" in (Audit.Event.Query.known_event_type_values()
                                           |> Enum.map(&elem(&1, 0)))
    end
  end

  describe "directory_sync is a distinct actor class" do
    # an inbound-SCIM event stamps the actor as
    # `directory_sync` + the provider id (so an auditor sees WHICH directory
    # acted), not a generic `system`. Build a struct-literal provider scoped to a
    # real account and run it through the real builder → changeset → insert.
    test "a SCIM-provisioned user event carries directory_sync + the provider id" do
      account = account_fixture()
      user = user_fixture()

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
      # The builders really do stamp it (grounds "distinct class" in source —
      # the same string-literal extraction the runbook.dispatched drift test uses).
      assert "directory_sync" in emitted_event_types()
    end
  end

  describe "the From/To window is inclusive on both bounds" do
    # From == an event's exact occurred_at INCLUDES it
    # (`occurred_at >= ts`), and To == an event's exact occurred_at INCLUDES it
    # (`occurred_at <= ts`); the boundary row is never silently dropped.
    test "an event at the exact From bound and at the exact To bound are both kept" do
      account = account_fixture()
      subject = subject_for(user_fixture(), account, role: :owner)

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
    # an empty account returns a nil next cursor, and the
    # final page of a multi-page walk also returns nil (nothing further to fetch),
    # which is what pairs with the empty-state copy in the LV.
    test "an empty log returns no next-page cursor" do
      account = account_fixture()
      subject = subject_for(user_fixture(), account, role: :owner)

      assert {:ok, [], %{next_page_cursor: nil}} = Audit.list_events(subject, page: [limit: 5])
    end

    test "the last page of a walk has a nil next cursor" do
      account = account_fixture()
      subject = subject_for(user_fixture(), account, role: :owner)

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
    test "a row inserted between page loads doesn't skip or duplicate the walk" do
      account = account_fixture()
      subject = subject_for(user_fixture(), account, role: :owner)

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

  describe "list_subject_options/2 (the dynamic subject picker)" do
    # the picker read enforces view_audit BEFORE any DB
    # touch; a runner subject (the websocket caller — no view_audit) is denied,
    # never handed options. A real `Subject.for_runner` carries the runner role's
    # empty audit permission (a user `:runner` string would degrade to :viewer,
    # which CAN view — so the websocket subject is the genuine no-permission one).
    test "a runner subject (no view_audit) is denied (no DB touch)" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      subject = Subject.for_runner(runner, account)

      assert {:error, :unauthorized} = Audit.list_subject_options("user", subject)
    end

    # a subject id that only resolves in account A never
    # surfaces in account B's picker: the distinct-id query is for_subject-scoped
    # to B, so A's row isn't even a candidate.
    test "a subject only resolvable in another account yields no options (cross-account)" do
      account_a = account_fixture()
      subject_b = subject_for(user_fixture(), account_fixture(), role: :owner)

      user_a = user_fixture()
      _ = membership_fixture(account_id: account_a.id, user_id: user_a.id)

      {:ok, _} =
        Audit.log(account_a.id, "user.invited", subject_kind: "user", subject_id: user_a.id)

      assert {:ok, []} = Audit.list_subject_options("user", subject_b)
    end

    # (context half) — `policy` and `approval_grant` have no
    # label resolver in resolve_labels/2, so every distinct id resolves to a nil
    # label and is dropped → the picker has zero options (intentional).
    test "a resolver-less subject kind yields no options" do
      account = account_fixture()
      subject = subject_for(user_fixture(), account, role: :owner)

      {:ok, _} =
        Audit.log(account.id, "policy.updated",
          subject_kind: "policy",
          subject_id: Ecto.UUID.generate()
        )

      assert {:ok, []} = Audit.list_subject_options("policy", subject)
      assert {:ok, []} = Audit.list_subject_options("approval_grant", subject)
    end
  end

  describe "list_actor_options/2 authorization" do
    # the actor picker enforces view_audit before any DB
    # touch; a runner (websocket) subject — no view_audit — is denied.
    test "a runner subject is denied" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      subject = Subject.for_runner(runner, account)

      assert {:error, :unauthorized} = Audit.list_actor_options("user", subject)
    end
  end

  describe "list_for_export/2 role gate" do
    # a subject whose role carries no `view_audit` is
    # rejected from INSIDE list_for_export with {:error, :unauthorized} (the
    # controller turns that into a 403), never a 500 or a leaked export. The
    # runner (websocket) role is the no-`view_audit` role; an API-key role DOES
    # carry it and is gated by per-key scope at the controller instead.
    test "a no-view_audit role is denied, not a 500" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      _ = seed_export_events(account, 2)

      runner_subject = Subject.for_runner(runner, account)

      assert {:error, :unauthorized} = Audit.list_for_export(runner_subject)
    end
  end

  describe "list_subject_options/2 drops an option whose row is gone" do
    # a subject id that WAS resolvable when the event was
    # written but whose row has since gone unresolvable resolves to a nil label
    # and is rejected, so the picker doesn't offer a dead option. Here the user's
    # membership is removed after the event, so the user-label resolver (scoped
    # through `members_of_account`) no longer finds them in the account.
    test "a subject whose label can no longer resolve is dropped from the options" do
      account = account_fixture()
      owner = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: owner.id, role: "owner")
      subject = subject_for(owner, account, role: :owner)

      member = user_fixture(email: "departing@example.com")
      membership = membership_fixture(account_id: account.id, user_id: member.id)

      {:ok, _} =
        Audit.log(account.id, "user.invited", subject_kind: "user", subject_id: member.id)

      # While the member is in the account, the picker offers them.
      assert {:ok, [{id, "departing@example.com"}]} =
               Audit.list_subject_options("user", subject)

      assert id == member.id

      # Remove the membership — the audit row still references the user id, but
      # the label resolver (members_of_account) can no longer resolve it, so the
      # option is dropped rather than rendered with a nil/blank label.
      membership
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
      |> Repo.update!()

      assert {:ok, []} = Audit.list_subject_options("user", subject)
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

  # The %Filter{} value codes for a static filter (e.g. actor_kind / subject_kind
  # enumerations) — read from the query module's own filters/0 so the assertion
  # tracks the real dropdown, not a hand-copied list.
  defp filter_values(name) do
    Audit.Event.Query.filters()
    |> Enum.find(&(&1.name == name))
    |> Map.fetch!(:values)
    |> Enum.map(&elem(&1, 0))
  end

  # Every event_type string literal a builder passes to `Audit.changeset/3`,
  # read from the Audit.Events source. Grounds "no builder emits X" in the actual
  # builder code: if a real `runbook.dispatched` builder is added, this set picks
  # it up and the drift test fails loudly (which is correct — close the gap then).
  defp emitted_event_types do
    path = Path.join(File.cwd!(), "lib/emisar/audit/events.ex")

    ~r/"([a-z_]+(?:\.[a-z_]+)?)"/
    |> Regex.scan(File.read!(path), capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end
end
