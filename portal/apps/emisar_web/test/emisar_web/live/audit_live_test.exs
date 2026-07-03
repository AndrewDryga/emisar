defmodule EmisarWeb.AuditLiveTest do
  @moduledoc """
  Smoke-tests the redesigned audit list + detail. Confirms IP column
  shows, subject labels are looked up live (so a renamed runner is
  reflected on next page load), the row links to a detail page, and
  the detail page renders payload + headers without crashing.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Audit, Repo}
  alias Emisar.Runners.Runner

  describe "GET /app/audit" do
    test "redirects anonymous users", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, ~p"/app/anon/audit")
    end

    test "renders rows with IP + a link into the subject's detail page", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      # Make a runner so we have a real subject to look up.
      {:ok, runner} =
        Runner.Changeset.register(%{
          account_id: account.id,
          name: "db-prod-01",
          external_id: Ecto.UUID.generate(),
          group: "default",
          hostname: "10.0.5.12",
          runner_version: "0.1.0"
        })
        |> Repo.insert()

      {:ok, _event} =
        Audit.log(account.id, "runner.connected",
          actor_kind: "runner",
          actor_id: runner.id,
          actor_label: runner.name,
          subject_kind: "runner",
          subject_id: runner.id,
          subject_label: runner.name,
          ip_address: "10.0.5.12",
          user_agent: "emisar-runner/0.1.0"
        )

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit")

      assert html =~ "runner.connected"
      assert html =~ "10.0.5.12"
      assert html =~ "db-prod-01"
      assert html =~ ~r/text-zinc-600[^>]*>\s*self\s*</
      # Subject/IP columns collapse below lg so the table fits a phone.
      assert html =~ "hidden lg:table-cell"
    end

    test "rows carry an outcome dot — rose for failures, amber for denials, neutral for routine",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      for {type, subject_kind} <- [
            {"user.sign_in_failed", "user"},
            {"approval.denied", "approval_request"},
            {"runner.connected", "runner"}
          ] do
        {:ok, _} = Audit.log(account.id, type, subject_kind: subject_kind, subject_label: "x")
      end

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit")

      assert html =~ "bg-rose-400"
      assert html =~ "bg-amber-400"
      assert html =~ "bg-zinc-600"
    end

    test "label updates reflect on next load (no stale snapshot)", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, runner} =
        Runner.Changeset.register(%{
          account_id: account.id,
          name: "old-name",
          external_id: Ecto.UUID.generate(),
          group: "default",
          runner_version: "0.1.0"
        })
        |> Repo.insert()

      {:ok, _event} =
        Audit.log(account.id, "runner.touched",
          subject_kind: "runner",
          subject_id: runner.id,
          subject_label: "old-name"
        )

      # Rename. The audit row still says "old-name" in subject_label.
      runner
      |> Ecto.Changeset.change(name: "renamed-prod")
      |> Repo.update!()

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit")

      # The live label takes precedence over the snapshot.
      assert html =~ "renamed-prod"
    end

    test "the actor links into a filtered audit view, and the date filters render in the bar",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      actor_id = Ecto.UUID.generate()

      {:ok, _} =
        Audit.log(account.id, "user.invited",
          actor_kind: "user",
          actor_id: actor_id,
          actor_label: "alice@example.com"
        )

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit")

      # The actor value links to "what did this identity do", not its
      # resource page.
      assert html =~ ~p"/app/#{account}/audit?actor_id=#{actor_id}"
      # From/To are real %Filter{} inputs in the unified LiveTable bar now —
      # not a separate hand-rolled date form.
      assert html =~ "From (UTC)"
      assert html =~ "To (UTC)"
      assert html =~ ~s(name="from")
      assert html =~ ~s(name="to")
      assert html =~ ~s(type="datetime-local")
      refute html =~ "Apply dates"
      # Request ID + Sign-in method are CONDITIONAL — with no Type selected they
      # never match all event types, so the panel hides them until a Type that
      # carries them is picked.
      refute html =~ ~s(name="request_id")
      refute html =~ ~s(name="auth_method")
    end

    test "an actor pivot (actor_kind + actor_id) filters the feed and shows a clearable chip",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      actor_id = Ecto.UUID.generate()

      {:ok, _} =
        Audit.log(account.id, "membership.role_changed",
          actor_kind: "user",
          actor_id: actor_id,
          actor_label: "admin@example.com"
        )

      {:ok, _} =
        Audit.log(account.id, "user.signed_in",
          actor_kind: "user",
          actor_id: Ecto.UUID.generate(),
          actor_label: "unrelated-human"
        )

      {:ok, _lv, html} =
        live(conn, ~p"/app/#{account}/audit?#{[actor_kind: "user", actor_id: actor_id]}")

      # The pivot resolves: the actor chip shows + rows scope to that actor.
      assert html =~ "Actor:"
      assert html =~ "admin@example.com"
      refute html =~ "unrelated-human"
    end

    test "the From date filter narrows to recent events", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      # Distinct actor_labels — event_type alone also appears in the filter
      # dropdown, so it can't tell a row apart from an option.
      {:ok, old} =
        Audit.log(account.id, "user.invited",
          actor_kind: "user",
          actor_id: Ecto.UUID.generate(),
          actor_label: "ancient-actor"
        )

      old
      |> Ecto.Changeset.change(occurred_at: DateTime.add(DateTime.utc_now(), -259_200, :second))
      |> Emisar.Repo.update!()

      {:ok, _} =
        Audit.log(account.id, "policy.updated",
          actor_kind: "user",
          actor_id: Ecto.UUID.generate(),
          actor_label: "fresh-actor"
        )

      # Unfiltered, the 3-day-old event shows.
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit")
      assert html =~ "ancient-actor"

      # A From bound 24h ago (datetime-local "YYYY-MM-DDTHH:MM", read as UTC)
      # drops the 3-day-old event and keeps the fresh one — applied through the
      # unified filter mechanism, no preset buttons or UTC math needed.
      from =
        DateTime.utc_now()
        |> DateTime.add(-86_400, :second)
        |> Calendar.strftime("%Y-%m-%dT%H:%M")

      {:ok, _lv2, html} = live(conn, ~p"/app/#{account}/audit?from=#{from}")
      assert html =~ "fresh-actor"
      refute html =~ "ancient-actor"
    end

    test "a relative-range preset chip narrows to the window (sets From to now − window)",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, old} =
        Audit.log(account.id, "user.invited",
          actor_kind: "user",
          actor_id: Ecto.UUID.generate(),
          actor_label: "ancient-actor"
        )

      old
      |> Ecto.Changeset.change(occurred_at: DateTime.add(DateTime.utc_now(), -259_200, :second))
      |> Emisar.Repo.update!()

      {:ok, _} =
        Audit.log(account.id, "policy.updated",
          actor_kind: "user",
          actor_id: Ecto.UUID.generate(),
          actor_label: "fresh-actor"
        )

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/audit")
      assert html =~ "ancient-actor"

      # Click "Last 24 hours": sets the unified bar's From to now − 24h, dropping the
      # 3-day-old event and keeping the fresh one — same effect as typing it.
      html = lv |> element("button", "Last 24 hours") |> render_click()
      assert html =~ "fresh-actor"
      refute html =~ "ancient-actor"
    end

    test "the Problems-only toggle filters to failures/denials without crashing (list-param round-trip)",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, _} =
        Audit.log(account.id, "user.sign_in_failed",
          actor_kind: "user",
          actor_id: Ecto.UUID.generate(),
          actor_label: "failed-signin"
        )

      {:ok, _} =
        Audit.log(account.id, "runner.connected",
          subject_kind: "runner",
          subject_label: "routine-runner"
        )

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/audit")
      assert html =~ "failed-signin"
      assert html =~ "routine-runner"

      # Toggling "Problems only" sets outcome=[danger, warn]; the list param must
      # round-trip — it crashed when URI.encode_query flattened it to "dangerwarn"
      # and the next render hit `"danger" in "dangerwarn"`.
      html = lv |> element("button", "Problems only") |> render_click()

      assert html =~ "failed-signin"
      refute html =~ "routine-runner"
    end

    test "a subject 'View activity' pivot filters to that subject and shows a clearable chip",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      runner_id = Ecto.UUID.generate()

      {:ok, _} =
        Audit.log(account.id, "runner.connected",
          subject_kind: "runner",
          subject_id: runner_id,
          subject_label: "pinned-runner"
        )

      {:ok, _} =
        Audit.log(account.id, "policy.updated",
          actor_kind: "user",
          actor_id: Ecto.UUID.generate(),
          actor_label: "unrelated-actor"
        )

      {:ok, _lv, html} =
        live(conn, ~p"/app/#{account}/audit?#{[subject_kind: "runner", subject_id: runner_id]}")

      # The pivot is visible as a clearable chip (it was invisible before — the
      # link filtered rows but surfaced no control)...
      assert html =~ "Subject:"
      assert html =~ "pinned-runner"
      # ...and the rows are actually scoped to that subject.
      refute html =~ "unrelated-actor"
    end

    test "a crafted preset window is a no-op (whitelist), not a crash or an arbitrary bound",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, _} =
        Audit.log(account.id, "user.invited",
          actor_kind: "user",
          actor_id: Ecto.UUID.generate(),
          actor_label: "still-here"
        )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/audit")

      # A forged window (not 1h/24h/7d) falls through to nil → no filter applied,
      # no crash. The list is unchanged.
      html = render_hook(lv, "preset", %{"window" => "99y; nonsense"})
      assert html =~ "still-here"
    end

    test "filtering by actor_id narrows the list and shows a clearable chip", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      actor_a = Ecto.UUID.generate()
      actor_b = Ecto.UUID.generate()

      {:ok, _} =
        Audit.log(account.id, "user.invited",
          actor_kind: "user",
          actor_id: actor_a,
          actor_label: "alice"
        )

      {:ok, _} =
        Audit.log(account.id, "policy.updated",
          actor_kind: "user",
          actor_id: actor_b,
          actor_label: "bob"
        )

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit?actor_id=#{actor_a}")

      assert html =~ "Actor:"
      assert html =~ "alice"
      # bob's event is filtered out entirely.
      refute html =~ "bob"
    end

    test "filtering by sign-in method narrows to that method's events", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, _} =
        Audit.log(account.id, "user.invited",
          actor_kind: "user",
          actor_label: "via-sso",
          auth_method: "sso"
        )

      {:ok, _} =
        Audit.log(account.id, "user.invited",
          actor_kind: "user",
          actor_label: "via-password",
          auth_method: "password"
        )

      # Sign-in method is conditional: a Type that carries it must be selected
      # first (user.invited is a user-session event, so both rows share it) —
      # then auth_method is what narrows to the sso session.
      {:ok, _lv, html} =
        live(conn, ~p"/app/#{account}/audit?event_type=user.invited&auth_method=sso")

      assert html =~ "via-sso"
      # the password-session event is filtered out.
      refute html =~ "via-password"
    end

    test "selecting an actor kind surfaces a picker of that kind's resolved actors",
         %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      {:ok, _} = Audit.log(account.id, "user.invited", actor_kind: "user", actor_id: user.id)

      # No kind selected → no actor picker rendered.
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit")
      refute html =~ ~s(name="actor_id")

      # One kind selected → the picker appears, listing the resolved actor.
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit?actor_kind=user")
      assert html =~ ~s(name="actor_id")
      assert html =~ ~s(value="#{user.id}")
      # …and right after its Actor-type trigger — before the next (Subject)
      # filter, not tacked on at the end.
      assert :binary.match(html, ~s(name="actor_id")) <
               :binary.match(html, ~s(name="subject_kind"))

      assert html =~ user.email
    end

    test "selecting a subject kind surfaces a picker of that kind's resolved subjects",
         %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      {:ok, _} = Audit.log(account.id, "user.invited", subject_kind: "user", subject_id: user.id)

      # No subject kind selected → no subject picker rendered.
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit")
      refute html =~ ~s(name="subject_id")

      # Pick "user" → the picker appears with the resolved subject (the user's
      # email), right after its Subject trigger — same shape as the actor picker.
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit?subject_kind=user")
      assert html =~ ~s(name="subject_id")
      assert html =~ ~s(value="#{user.id}")
      assert html =~ user.email

      assert :binary.match(html, ~s(name="subject_kind")) <
               :binary.match(html, ~s(name="subject_id"))
    end

    # `approval_grant` and `policy` have no label resolver,
    # so their distinct-id options all resolve to nil and are rejected → the
    # dependent picker never renders (intentional; you filter those by Type).
    test "a subject kind with no label resolver surfaces no picker", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      # Real rows of the resolver-less kinds — the picker still must not appear.
      {:ok, _} =
        Audit.log(account.id, "approval.grant_revoked",
          subject_kind: "approval_grant",
          subject_id: Ecto.UUID.generate()
        )

      {:ok, _} =
        Audit.log(account.id, "policy.updated",
          subject_kind: "policy",
          subject_id: Ecto.UUID.generate()
        )

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit?subject_kind=approval_grant")
      refute html =~ ~s(name="subject_id")

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit?subject_kind=policy")
      refute html =~ ~s(name="subject_id")
    end

    # picking an actor then switching the Actor *type*
    # invalidates the pick (its id belongs to the old kind), so actor_id is
    # dropped from the patched URL; the new kind's picker reads "All".
    test "switching the actor kind drops the now-invalid actor pick", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      {:ok, _} = Audit.log(account.id, "user.invited", actor_kind: "user", actor_id: user.id)

      # Land with a user actor picked (kind + id both in the params).
      {:ok, lv, _html} =
        live(conn, ~p"/app/#{account}/audit?actor_kind=user&actor_id=#{user.id}")

      # Switch the actor kind to api_key — the stale user actor_id must not ride along.
      lv
      |> form("#audit-events-filter", %{actor_kind: "api_key"})
      |> render_change()

      assert_patch(lv, ~p"/app/#{account}/audit?actor_kind=api_key")
    end

    # same for the Subject picker: a changed subject kind
    # invalidates the previously-picked subject_id, dropping it from the URL.
    test "switching the subject kind drops the stale subject pick", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      {:ok, _} = Audit.log(account.id, "user.invited", subject_kind: "user", subject_id: user.id)

      {:ok, lv, _html} =
        live(conn, ~p"/app/#{account}/audit?subject_kind=user&subject_id=#{user.id}")

      lv
      |> form("#audit-events-filter", %{subject_kind: "runner"})
      |> render_change()

      assert_patch(lv, ~p"/app/#{account}/audit?subject_kind=runner")
    end

    # a crafted/blank actor_id is normalized: a junk UUID is
    # account-scoped to zero rows (no crash, rich empty state), and a blank one
    # is dropped so no chip renders.
    test "a crafted or blank actor_id is normalized, never a crash", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, _} = Audit.log(account.id, "user.invited", actor_kind: "user", actor_label: "real")

      # A well-formed but unknown id → account-scoped to nothing, no crash.
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit?actor_id=#{Ecto.UUID.generate()}")
      assert html =~ "No events match these filters."
      refute html =~ "real"

      # A blank actor_id → blank_to_nil drops it, so no actor chip renders and
      # the unfiltered feed comes back.
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit?actor_id=")
      refute html =~ "Actor:"
      assert html =~ "real"
    end

    # same normalization for a crafted/blank subject_id.
    test "a crafted or blank subject_id is normalized, never a crash", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, _} =
        Audit.log(account.id, "user.invited", subject_kind: "user", subject_label: "real")

      {:ok, _lv, html} =
        live(conn, ~p"/app/#{account}/audit?subject_kind=user&subject_id=#{Ecto.UUID.generate()}")

      assert html =~ "No events match these filters."
      refute html =~ "real"

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit?subject_id=")
      assert html =~ "real"
    end

    # the quick-range preset computes its From
    # at CLICK time (anchored to now, via preset_from/1) and clears any
    # previously-set To. Land with a To set, click "Last hour": the patched URL
    # carries a fresh `from` and no `to`.
    test "a preset is computed at click-time and clears a previously-set To", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, _} = Audit.log(account.id, "user.invited", actor_kind: "user", actor_label: "x")

      # Arrive with an explicit To upper bound in the params.
      future =
        DateTime.utc_now()
        |> DateTime.add(3600, :second)
        |> Calendar.strftime("%Y-%m-%dT%H:%M")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/audit?to=#{future}")

      lv |> element("button", "Last hour") |> render_click()

      to = assert_patch(lv)
      %{query: query} = URI.parse(to)
      params = URI.decode_query(query)

      # `from` is freshly computed (present, ~1h ago) and `to` is gone.
      assert Map.has_key?(params, "from")
      refute Map.has_key?(params, "to")

      {:ok, from_dt, _} = DateTime.from_iso8601(params["from"] <> ":00Z")
      # Anchored to "now" — within a minute of (now − 1h), not page-render-stale.
      assert_in_delta DateTime.diff(DateTime.utc_now(), from_dt, :second), 3600, 90
    end

    # the timeline is live: on mount it subscribes to the
    # account audit topic, and a committed `{:audit_event, _}` reloads the
    # current filter so a new row appears without a refresh. Simulate the
    # broadcast the way Repo.commit_multi fans it out.
    test "a new committed event auto-reloads the feed via the audit broadcast", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/audit")

      refute html =~ "freshly-committed-actor"

      # Commit a new row, then deliver the broadcast the LV subscribed to.
      {:ok, event} =
        Audit.log(account.id, "user.invited",
          actor_kind: "user",
          actor_id: Ecto.UUID.generate(),
          actor_label: "freshly-committed-actor"
        )

      send(lv.pid, {:audit_event, event})
      assert render(lv) =~ "freshly-committed-actor"
    end

    # an account with zero events shows the RICH empty
    # state (naming the surfaces that produce events), distinct from the terse
    # filtered-empty one-liner. A fresh account already has its `account.created`
    # row, so clear the log to reach the genuinely-empty state.
    test "an empty log with no filter shows the rich empty state", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      clear_audit_log(account.id)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit")

      assert html =~ "No audit events yet."
      # Names the event-producing surfaces, not the terse filtered copy.
      assert html =~ "Packs page"
      refute html =~ "No events match these filters."
    end

    # when a (type) filter matches nothing, the feed shows
    # the terse one-liner, NOT the rich empty-account copy: over-filtering must
    # read differently from "this account has never done anything".
    test "a filter that matches nothing shows the terse filtered-empty copy", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, _} = Audit.log(account.id, "user.invited", actor_kind: "user", actor_label: "real")

      # Filter to a Type with no rows in this account (the single-select Type
      # control submits a scalar value).
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit?event_type=runner.deleted")

      assert html =~ "No events match these filters."
      refute html =~ "No audit events yet."
    end

    # the actor chip's clear (✕) link drops `actor_id` from
    # the params, restoring the full feed (the previously-filtered-out rows
    # return). The clear link patches to the URL without actor_id.
    test "clearing the actor chip restores the full feed", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      actor_a = Ecto.UUID.generate()

      {:ok, _} =
        Audit.log(account.id, "user.invited",
          actor_kind: "user",
          actor_id: actor_a,
          actor_label: "alice"
        )

      {:ok, _} =
        Audit.log(account.id, "policy.updated", actor_kind: "user", actor_label: "bob")

      # Land filtered to alice — bob is out, and the clear link is present.
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/audit?actor_id=#{actor_a}")
      assert html =~ "Actor:"
      refute html =~ "bob"

      # Click the chip's clear (✕) — actor_id drops, the full feed returns.
      html = lv |> element(~s(a[aria-label="Clear actor filter"])) |> render_click()
      refute html =~ "Actor:"
      assert html =~ "bob"
    end

    # an active click-to-filter `actor_id` (which rides the
    # URL, not the form) survives an UNRELATED dropdown change: the filter event
    # merges it back rather than silently dropping it when the form re-submits
    # without it.
    test "an active actor_id survives an unrelated filter change", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      actor_a = Ecto.UUID.generate()

      {:ok, _} =
        Audit.log(account.id, "user.invited",
          actor_kind: "user",
          actor_id: actor_a,
          actor_label: "alice",
          auth_method: "sso"
        )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/audit?actor_id=#{actor_a}")

      # Change an unrelated filter (Outcome — always visible) — actor_id must
      # ride along.
      lv
      |> form("#audit-events-filter", %{outcome: "danger"})
      |> render_change()

      to = assert_patch(lv)
      %{query: query} = URI.parse(to)
      params = URI.decode_query(query)
      assert params["actor_id"] == actor_a
      assert params["outcome"] == "danger"
    end

    # a chip for an actor that isn't in the loaded rows (its
    # id filters to zero events) falls back to showing the RAW id, never a crash
    # or a blank chip: actor_label_for/2 returns the id when no event matches.
    test "a stale actor chip falls back to the raw id", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, _} = Audit.log(account.id, "user.invited", actor_kind: "user", actor_label: "real")

      stale = Ecto.UUID.generate()
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit?actor_id=#{stale}")

      # The chip renders with the raw id (no loaded event carries a label for it).
      assert html =~ "Actor:"
      assert html =~ stale
      assert html =~ "No events match these filters."
    end

    # a quick-range preset only touches from/to; an
    # unrelated active filter (a Type pick) is preserved across the click.
    test "a preset preserves an unrelated active filter", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, _} = Audit.log(account.id, "user.invited", actor_kind: "user", actor_label: "x")

      # Land with a Type filter already active (single-select → scalar value).
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/audit?event_type=user.invited")

      lv |> element("button", "Last hour") |> render_click()

      to = assert_patch(lv)
      %{query: query} = URI.parse(to)
      params = URI.decode_query(query)

      # from was added by the preset; the Type filter rode along untouched.
      assert Map.has_key?(params, "from")
      assert params["event_type"] == "user.invited"
    end

    # selecting an Actor kind that has NO actors of that
    # kind in the log surfaces no dependent picker: the `{:ok, [_|_]}` guard
    # fails on an empty option list, so the actor_id <select> isn't rendered.
    test "an actor kind with no actors in the log surfaces no picker", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      # A user-actor row exists, but NO runner-actor rows — so picking the
      # runner kind must not render a picker.
      {:ok, _} = Audit.log(account.id, "user.invited", actor_kind: "user", actor_label: "x")

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit?actor_kind=runner")
      refute html =~ ~s(name="actor_id")
    end

    # same for the Subject picker: a subject kind with no
    # subjects of that kind in the log renders no dependent picker.
    test "a subject kind with no subjects in the log surfaces no picker", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, _} = Audit.log(account.id, "user.invited", subject_kind: "user", subject_label: "x")

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit?subject_kind=runner")
      refute html =~ ~s(name="subject_id")
    end

    # a system / scheduler / runbook actor has no
    # identifying row in another table, so it renders a clean label ("System")
    # with NO colon-id pair (which would read the meaningless "system: —").
    test "a system actor renders a clean label, not a kind:id pair", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, _} =
        Audit.log(account.id, "action_run.denied",
          actor_kind: "system",
          subject_kind: "action_run",
          subject_label: "linux.uptime"
        )

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit")

      # The actor cell reads "System" with no colon-id pair for it. (The literal
      # "system:" would only appear if the kind:id ref shape were used.)
      assert html =~ "System"
      refute html =~ "system:"
    end

    # crafted filter params from a hand-edited URL are
    # normalized: blank values are dropped (blank_to_nil) and unknown keys are
    # ignored by params_to_opts, so the feed loads cleanly instead of crashing.
    test "crafted / blank / unknown filter params are normalized, never a crash", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, _} = Audit.log(account.id, "user.invited", actor_kind: "user", actor_label: "real")

      # Blank event_type + an unknown filter key the LV never declares.
      {:ok, _lv, html} =
        live(conn, ~p"/app/#{account}/audit?event_type=&actor_kind=&totally_made_up_key=zzz")

      # No crash; the real row still loads (nothing was actually filtered).
      assert html =~ "real"
    end

    # a bad pagination cursor from a hand-edited
    # URL (the keyset `?after=<opaque>`) makes list_events return
    # {:error, :invalid_cursor}; the LV retries once with empty params and loads
    # the feed cleanly rather than crashing or showing a broken page.
    test "a hand-edited bad page cursor retries once and loads the feed", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, _} =
        Audit.log(account.id, "user.invited", actor_kind: "user", actor_label: "still-here")

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit?after=not-a-real-cursor")

      # The clean retry won — the row is shown and the load-error state is not.
      assert html =~ "still-here"
      refute html =~ "Couldn't load the audit log"
    end
  end

  describe "keyset pagination is account-scoped across pages" do
    # walking page → next as account B never pages in any of
    # account A's events: every page is scoped by for_subject/2. Seed enough A
    # rows to span multiple pages, then confirm B's walk yields only B's rows.
    test "account B's cursor walk never pages in account A's events", %{conn: conn} do
      {conn, _user, account_b} = register_and_log_in(conn)

      # Account A (a separate tenant) has a full page-plus of events.
      other = Fixtures.Accounts.create_account()

      for i <- 1..30 do
        {:ok, _} =
          Audit.log(other.id, "user.invited",
            actor_kind: "user",
            actor_label: "A-secret-#{i}"
          )
      end

      # Account B has a couple of its own, distinctly labelled.
      for i <- 1..2 do
        {:ok, _} =
          Audit.log(account_b.id, "user.invited",
            actor_kind: "user",
            actor_label: "B-own-#{i}"
          )
      end

      # B's first page: only B's rows, never A's — even though A has far more.
      {:ok, lv, html} = live(conn, ~p"/app/#{account_b}/audit")
      assert html =~ "B-own-1"
      refute html =~ "A-secret"

      # Walk forward through whatever pages B has; A's events must never appear.
      html = walk_all_pages(lv, html)
      refute html =~ "A-secret"
    end
  end

  describe "GET /app/audit/:id" do
    setup %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      %{conn: conn, account: account}
    end

    test "renders the full payload + IP + UA", %{conn: conn, account: account} do
      {:ok, event} =
        Audit.log(account.id, "api_key.created",
          actor_kind: "user",
          actor_label: "owner@example.com",
          subject_kind: "api_key",
          subject_label: "ci-bot",
          ip_address: "203.0.113.7",
          user_agent: "Mozilla/5.0 (Macintosh)",
          payload: %{prefix: "emk-abcdef", scopes: ["actions:read", "actions:execute"]}
        )

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit/#{event.id}")

      assert html =~ "api_key.created"
      assert html =~ "203.0.113.7"
      assert html =~ "Mozilla/5.0 (Macintosh)"
      assert html =~ "actions:execute"
      assert html =~ "owner@example.com"
      # Subject of kind api_key links to the agents page (where keys live).
      assert html =~ ~p"/app/#{account}/settings/agents"
    end

    test "parses bridge user agent into client + host + os posture fields", %{
      conn: conn,
      account: account
    } do
      {:ok, event} =
        Audit.log(account.id, "linux.uptime.run",
          actor_kind: "api_key",
          actor_label: "Claude Desktop",
          subject_kind: "action_run",
          subject_label: "linux.uptime",
          ip_address: "127.0.0.1",
          user_agent: "emisar-mcp/dev (client=claude-desktop; host=andrews-mbp.local; os=darwin)"
        )

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit/#{event.id}")

      assert html =~ "claude-desktop"
      assert html =~ "andrews-mbp.local"
      # The host's OS, parsed from the same UA posture block.
      assert html =~ "darwin"
      assert html =~ "emisar-mcp/dev"
      # The raw UA is still shown below the cards for forensics.
      assert html =~ "emisar-mcp/dev (client=claude-desktop"
    end

    test "shows the MCP session id when the event carries one", %{conn: conn, account: account} do
      {:ok, event} =
        Audit.log(account.id, "action_run.success",
          actor_kind: "api_key",
          actor_label: "Claude Code",
          subject_kind: "action_run",
          subject_label: "nomad.job_status",
          ip_address: "127.0.0.1",
          user_agent: "emisar-mcp/0.1.1 (client=claude-code; host=mac)",
          mcp_session_id: "5985d95cf73715ff"
        )

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit/#{event.id}")

      assert html =~ "MCP session"
      assert html =~ "5985d95cf73715ff"
    end

    test "redirects to list with flash when event id is unknown", %{conn: conn, account: account} do
      missing = Ecto.UUID.generate()

      dest = ~p"/app/#{account}/audit"

      assert {:error, {:live_redirect, %{to: ^dest}}} =
               live(conn, ~p"/app/#{account}/audit/#{missing}")
    end

    test "events from other accounts 404 (account scoping)", %{conn: conn, account: account} do
      # Brand-new account the logged-in user has no membership in.
      other = Fixtures.Accounts.create_account()

      {:ok, event} = Audit.log(other.id, "secret.event", actor_kind: "system")

      dest = ~p"/app/#{account}/audit"

      assert {:error, {:live_redirect, %{to: ^dest}}} =
               live(conn, ~p"/app/#{account}/audit/#{event.id}")
    end
  end

  describe "SIEM export keys" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      %{conn: conn, user: user, account: account}
    end

    test "mint shows the secret once, list updates, revoke retires it", %{
      conn: conn,
      user: user,
      account: account
    } do
      subject = Fixtures.Subjects.subject_for(user, account)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/audit")

      # Mint: the raw emk- secret is rendered exactly once.
      html = render_click(lv, "create_export_key", %{})
      assert html =~ "emk-"
      assert html =~ "Audit export —"

      html = render_click(lv, "dismiss_export_secret", %{})
      refute html =~ "emk-NOSUCH"

      # The minted key row is in the export list; revoke it.
      {:ok, [key], _meta} =
        Emisar.ApiKeys.list_audit_export_keys_for_account(subject, page_size: 50)

      html = render_click(lv, "revoke_export_key", %{"id" => key.id})
      assert html =~ "Export token revoked."

      # Revoked keys stay listed (audit trail) but carry the revocation.
      {:ok, [revoked], _meta} =
        Emisar.ApiKeys.list_audit_export_keys_for_account(subject, page_size: 50)

      assert revoked.revoked_at
    end

    # an account with no export tokens shows
    # the mint affordance but NOT the (empty) list section: the list div is
    # `:if={@export_keys != []}`, so a manager sees just the "Mint export token"
    # button until they've created one.
    test "with no export keys the list is hidden but the mint affordance shows", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/audit")

      # The SIEM card + mint button are present (the owner manages keys)…
      assert html =~ "SIEM export"
      assert html =~ "Mint export token"
      # …but with zero export tokens the list section is hidden — so no list-row
      # Revoke affordance renders (the header copy mentions audit:read regardless,
      # so the list's presence is the real signal). Scope to the card to be sure.
      siem_card = lv |> element("#siem-export") |> render()
      refute siem_card =~ "revoke_export_key"
      refute siem_card =~ "Revoked"
    end

    # while a freshly-minted secret is being revealed, the
    # "Mint export token" button is hidden (`:if={is_nil(@export_secret)}`) so a
    # double-mint can't clobber the one-shot reveal; dismissing brings it back.
    test "the mint button is hidden while a secret is being revealed", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/audit")
      assert html =~ "Mint export token"

      html = render_click(lv, "create_export_key", %{})
      # The secret is shown and the mint button is gone during the reveal.
      assert html =~ "emk-"
      refute html =~ "Mint export token"

      # Dismissing the reveal restores the mint button.
      html = render_click(lv, "dismiss_export_secret", %{})
      assert html =~ "Mint export token"
    end

    # the curl snippet's base URL is derived from the socket
    # (`derive_base_url(socket) <> "/api/audit"`), so the reveal hands the
    # operator a copy-paste command pointed at this deployment's export endpoint.
    test "the reveal shows a curl snippet pointed at /api/audit", %{conn: conn, account: account} do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/audit")

      html = render_click(lv, "create_export_key", %{})

      assert html =~ "/api/audit"
      assert html =~ "curl -H"
      assert html =~ "Authorization: Bearer"
    end

    # the mint surface hardcodes the scope to
    # ["audit:read"]; crafted extra params on the event can't widen it. An
    # operator can't escalate a log-shipping token into an action-executing one
    # from this page.
    test "crafted scope params on the mint event cannot widen the token's scope", %{
      conn: conn,
      user: user,
      account: account
    } do
      subject = Fixtures.Subjects.subject_for(user, account)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/audit")

      # Fire the mint event with attacker-supplied scope params.
      _ =
        render_click(lv, "create_export_key", %{
          "scopes" => ["audit:read", "actions:execute"],
          "name" => "smuggled"
        })

      # The minted key carries audit:read ONLY — the crafted params were ignored.
      {:ok, [key], _meta} =
        Emisar.ApiKeys.list_audit_export_keys_for_account(subject, page_size: 50)

      assert key.scopes == ["audit:read"]
    end

    # the raw secret is one-shot: it lives only
    # in the socket assigns, so a fresh mount (a reconnect / reload) never
    # re-shows it. Mint in one session, then open a second LV: no secret.
    test "the minted secret is one-shot — a fresh mount never re-shows it", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/audit")

      html = render_click(lv, "create_export_key", %{})
      [raw] = Regex.run(~r/Bearer (emk-[A-Za-z0-9_-]+)/, html, capture: :all_but_first)

      # A brand-new mount of the same page (reconnect) must not carry the secret.
      {:ok, _lv2, fresh_html} = live(conn, ~p"/app/#{account}/audit")
      refute fresh_html =~ raw
      refute fresh_html =~ "won't show it again"
    end

    # the Revoke button renders only for non-revoked keys
    # (`:if={is_nil(key.revoked_at)}`); a revoked key shows the "Revoked" chip and
    # no button — idempotency by affordance.
    test "revoke is offered only on active keys; revoked keys show a chip", %{
      conn: conn,
      user: user,
      account: account
    } do
      subject = Fixtures.Subjects.subject_for(user, account)

      {:ok, _raw, active} =
        Emisar.ApiKeys.create_key(%{name: "active-export", scopes: ["audit:read"]}, subject)

      {:ok, _raw, to_revoke} =
        Emisar.ApiKeys.create_key(%{name: "dead-export", scopes: ["audit:read"]}, subject)

      {:ok, _} = Emisar.ApiKeys.revoke_api_key(to_revoke, subject)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/audit")
      siem_card = lv |> element("#siem-export") |> render()

      # The active key offers a Revoke button keyed to its id…
      assert siem_card =~ ~s(phx-value-id="#{active.id}")
      # …the revoked key does NOT (no button keyed to it) but shows the chip.
      refute siem_card =~ ~s(phx-value-id="#{to_revoke.id}")
      assert siem_card =~ "Revoked"
    end

    # a key whose creating user has since been deleted still
    # lists (left-join preload → created_by is nil), and the "by <email>" line is
    # guarded (`:if={key.created_by}`) so the row renders without crashing.
    test "a key whose creator was deleted renders without the 'by' line", %{
      conn: conn,
      account: account
    } do
      # A second admin mints the export token, then their user row is soft-deleted
      # (we stay logged in as the original owner so the page still mounts).
      other_admin = Fixtures.Users.create_user(email: "departing-admin@example.com")

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: other_admin.id,
          role: "admin"
        )

      other_subject = Fixtures.Subjects.subject_for(other_admin, account, role: :admin)

      {:ok, _raw, _key} =
        Emisar.ApiKeys.create_key(%{name: "orphan-export", scopes: ["audit:read"]}, other_subject)

      # Soft-delete the creator — created_by (a where: deleted_at: nil belongs_to)
      # now resolves to nil on the preload.
      other_admin
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
      |> Emisar.Repo.update!()

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/audit")
      siem_card = lv |> element("#siem-export") |> render()

      # The key still lists; the guarded "by <email>" line is simply absent.
      assert siem_card =~ "orphan-export"
      refute siem_card =~ "departing-admin@example.com"
    end

    test "a viewer cannot mint an export key", %{account: account} do
      viewer = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      {:ok, lv, _html} = build_conn() |> log_in_user(viewer) |> live(~p"/app/#{account}/audit")

      html = render_click(lv, "create_export_key", %{})
      assert html =~ "You don&#39;t have permission to do that."
      refute html =~ "emk-"
    end

    test "an api_key list_changed broadcast refreshes the key list", %{
      conn: conn,
      user: user,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/audit")

      # A key minted elsewhere (another tab/admin) appears via the broadcast.
      subject = Fixtures.Subjects.subject_for(user, account)

      {:ok, _raw, key} =
        Emisar.ApiKeys.create_key(
          %{name: "Side-channel export", scopes: ["audit:read"]},
          subject
        )

      send(lv.pid, {:list_changed, :api_key, "api_key.created", key.id})
      assert render(lv) =~ "Side-channel export"
    end

    test "an operator cannot revoke an export key (crafted event denied)", %{
      user: owner,
      account: account
    } do
      # An owner-minted export token; the operator below must not be able to
      # retire it from a crafted event (managing keys needs admin+).
      owner_subject = Fixtures.Subjects.subject_for(owner, account)

      {:ok, _raw, key} =
        Emisar.ApiKeys.create_key(
          %{name: "Owner export token", scopes: ["audit:read"]},
          owner_subject
        )

      operator = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      {:ok, lv, _html} =
        build_conn() |> log_in_user(operator) |> live(~p"/app/#{account}/audit")

      html = render_click(lv, "revoke_export_key", %{"id" => key.id})
      assert html =~ "You don&#39;t have permission to do that."

      # The token is untouched — still active.
      {:ok, [reread], _meta} =
        Emisar.ApiKeys.list_audit_export_keys_for_account(owner_subject, page_size: 50)

      assert is_nil(reread.revoked_at)
    end

    test "revoking a bogus key id is a silent no-op, not a crash or a flash", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/audit")

      # A well-formed but nonexistent id: fetch_api_key_by_id returns
      # {:error, :not_found}, so the handler does nothing — no info flash.
      html = render_click(lv, "revoke_export_key", %{"id" => Ecto.UUID.generate()})
      refute html =~ "Export token revoked."

      # A malformed (non-UUID) id is rejected pre-query, same no-op.
      html = render_click(lv, "revoke_export_key", %{"id" => "not-a-uuid"})
      refute html =~ "Export token revoked."
    end

    test "an admin cannot revoke another account's export key (cross-account no-op)", %{
      conn: conn,
      account: account_b
    } do
      # Account A (a different tenant) has its own export token. The admin of B
      # fires revoke with A's real key id — the subject-gated fetch scopes to B,
      # so A's key is never found and never revoked.
      {a_user, _account_a, a_subject} = Fixtures.Subjects.owner_subject()
      _ = a_user

      {:ok, _raw, a_key} =
        Emisar.ApiKeys.create_key(
          %{name: "Account A export token", scopes: ["audit:read"]},
          a_subject
        )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account_b}/audit")

      html = render_click(lv, "revoke_export_key", %{"id" => a_key.id})
      refute html =~ "Export token revoked."

      # A's token is untouched.
      {:ok, [reread], _meta} =
        Emisar.ApiKeys.list_audit_export_keys_for_account(a_subject, page_size: 50)

      assert reread.id == a_key.id
      assert is_nil(reread.revoked_at)
    end

    test "a revoked export token returns 401 from the export endpoint on its next call",
         %{conn: conn, user: user, account: account} do
      subject = Fixtures.Subjects.subject_for(user, account)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/audit")

      # Mint via the page; the raw secret only exists in the reveal once, so
      # parse it out of the rendered curl snippet.
      html = render_click(lv, "create_export_key", %{})
      [raw] = Regex.run(~r/Bearer (emk-[A-Za-z0-9_-]+)/, html, capture: :all_but_first)

      # The fresh token works.
      ok = build_conn() |> put_req_header("authorization", "Bearer #{raw}") |> get(~p"/api/audit")
      assert ok.status == 200

      # Revoke it on the page, then the collector's next poll is rejected.
      {:ok, [key], _meta} =
        Emisar.ApiKeys.list_audit_export_keys_for_account(subject, page_size: 50)

      _ = render_click(lv, "revoke_export_key", %{"id" => key.id})

      denied =
        build_conn() |> put_req_header("authorization", "Bearer #{raw}") |> get(~p"/api/audit")

      assert json_response(denied, 401) == %{"error" => "unauthorized"}
    end

    test "the SIEM card is hidden from a non-manager (operator)", %{account: account} do
      operator = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      {:ok, _lv, html} =
        build_conn() |> log_in_user(operator) |> live(~p"/app/#{account}/audit")

      # An operator can read the audit log but not manage keys → no SIEM card.
      refute html =~ "SIEM export"
      refute html =~ "Mint export token"
    end

    test "another account's export tokens never appear in this account's SIEM list",
         %{conn: conn, account: account_b} do
      # Account A mints a distinctively-named export token.
      {a_user, _account_a, a_subject} = Fixtures.Subjects.owner_subject()
      _ = a_user

      {:ok, _raw, _a_key} =
        Emisar.ApiKeys.create_key(
          %{name: "Account-A-only-export-token", scopes: ["audit:read"]},
          a_subject
        )

      # Viewing B's audit page must not surface A's token.
      {:ok, _lv, html} = live(conn, ~p"/app/#{account_b}/audit")
      refute html =~ "Account-A-only-export-token"
    end

    test "audit:read tokens are bucketed out of the LLM agents page", %{
      conn: conn,
      user: user,
      account: account
    } do
      subject = Fixtures.Subjects.subject_for(user, account)

      # An export token (audit:read) and an MCP token (actions:*). The audit
      # page shows the export one; the agents page shows the MCP one — the two
      # buckets never overlap (without_scope("audit:read") there).
      {:ok, _raw, _export} =
        Emisar.ApiKeys.create_key(
          %{name: "ZZ-siem-export-token", scopes: ["audit:read"]},
          subject
        )

      {:ok, _raw, _mcp} =
        Emisar.ApiKeys.create_key(
          %{name: "ZZ-mcp-bridge-token", scopes: ["actions:read", "actions:execute"]},
          subject
        )

      # The audit page's SIEM card lists the export token, not the MCP one.
      # (Both names also appear in the audit *timeline* as `api_key.created`
      # rows — minting logs an audit event — so scope the bucket assertion to
      # the SIEM card itself, which is the list under test.)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/audit")
      siem_card = lv |> element("#siem-export") |> render()
      assert siem_card =~ "ZZ-siem-export-token"
      refute siem_card =~ "ZZ-mcp-bridge-token"

      # The agents page lists the MCP token, not the export one.
      {:ok, _lv, agents_html} = live(conn, ~p"/app/#{account}/settings/agents")
      assert agents_html =~ "ZZ-mcp-bridge-token"
      refute agents_html =~ "ZZ-siem-export-token"
    end
  end

  # Empty an account's audit log so the genuinely-empty state can be tested — a
  # fresh account already carries its `account.created` / `user.signed_up` rows.
  # Building the queryable straight from the Query module is the sanctioned
  # test-fixture shape (§7).
  defp clear_audit_log(account_id) do
    Audit.Event.Query.all()
    |> Audit.Event.Query.by_account_id(account_id)
    |> Repo.delete_all()
  end

  # Click "Next →" until the pager runs out, returning every page's HTML
  # concatenated, so an assertion can confirm something never appears on ANY
  # page of the keyset walk (not just the first). Bounded by a hard step count
  # so a pager bug can't loop the test forever.
  defp walk_all_pages(lv, html, acc \\ "", steps \\ 20)
  defp walk_all_pages(_lv, html, acc, 0), do: acc <> html

  defp walk_all_pages(lv, html, acc, steps) do
    next = element(lv, "#audit-events-pager a", "Next")

    if has_element?(next) do
      walk_all_pages(lv, render_click(next), acc <> html, steps - 1)
    else
      acc <> html
    end
  end
end
