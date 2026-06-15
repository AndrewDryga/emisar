defmodule Emisar.AuditTest do
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.{Approvals, Audit, RequestContext, Runbooks, Runs}

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
  end

  describe "Audit.Events builders inherit the subject's request context" do
    setup do
      account = account_fixture()
      user = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
      %{account: account, user: user}
    end

    test "a builder stamps actor + the subject's context onto the event", ctx do
      context = %RequestContext{
        ip_address: "203.0.113.7",
        user_agent: "Mozilla/5.0",
        request_id: "req_evt",
        mcp_session_id: "sess_evt"
      }

      subject = subject_for(ctx.user, ctx.account, role: :owner, context: context)

      {:ok, event} = Audit.record(Audit.Events.account_updated(subject, ctx.account))

      # Actor identity comes off the subject…
      assert event.actor_kind == "user"
      assert event.actor_id == ctx.user.id
      # …and so does the request metadata — the lever that lets every
      # builder inherit ip/ua/request_id/mcp_session without threading a conn.
      assert event.ip_address == "203.0.113.7"
      assert event.user_agent == "Mozilla/5.0"
      assert event.request_id == "req_evt"
      assert event.mcp_session_id == "sess_evt"
    end

    test "a subject with the default (empty) context yields no request metadata", ctx do
      subject = subject_for(ctx.user, ctx.account, role: :owner)

      {:ok, event} = Audit.record(Audit.Events.account_updated(subject, ctx.account))

      assert event.actor_id == ctx.user.id
      assert event.ip_address == nil
      assert event.user_agent == nil
      assert event.request_id == nil
      assert event.mcp_session_id == nil
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
end
