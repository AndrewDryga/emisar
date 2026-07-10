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

    test "renders rows as one-line events — label, meta with IP, detail link", %{conn: conn} do
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
          target_kind: "runner",
          target_id: runner.id,
          target_label: runner.name,
          ip_address: "10.0.5.12",
          user_agent: "emisar-runner/0.1.0"
        )

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit")

      # ONE identity per row — the human label; the machine code lives on the
      # detail page. The meta fragment carries the actor by name + the IP; a
      # self-event (subject == actor) repeats no subject.
      assert html =~ "Runner connected"
      refute html =~ "runner.connected</span>"
      assert html =~ "10.0.5.12"
      assert html =~ "db-prod-01"
      refute html =~ "db-prod-01 · → db-prod-01"
      # The whole row is the one link — into the EVENT detail.
      event =
        Repo.all(Emisar.Audit.Event) |> Enum.find(&(&1.event_type == "runner.connected"))

      assert html =~ ~p"/app/#{account}/audit/#{event.id}"
      # No day bands (relative times carry recency; the exact stamp rides each
      # row's tooltip) — the column header is the list's first row.
      assert html =~ "Source IP"
    end

    test "rows carry an outcome dot — rose failures, amber denials, brand passes, neutral routine",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      for {type, target_kind} <- [
            {"user.sign_in_failed", "user"},
            {"approval.denied", "approval_request"},
            {"action_run.success", "runner"},
            {"runner.connected", "runner"}
          ] do
        {:ok, _} = Audit.log(account.id, type, target_kind: target_kind, target_label: "x")
      end

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit")

      assert html =~ "bg-rose-400"
      assert html =~ "bg-amber-400"
      assert html =~ "bg-brand-400"
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
          target_kind: "runner",
          target_id: runner.id,
          target_label: "old-name"
        )

      # Rename. The audit row still says "old-name" in target_label.
      runner
      |> Ecto.Changeset.change(name: "renamed-prod")
      |> Repo.update!()

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit")

      # The live label takes precedence over the snapshot.
      assert html =~ "renamed-prod"
    end

    test "rows name the actor, and the date filters render in the facet panel",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      actor_id = Ecto.UUID.generate()

      {:ok, _} =
        Audit.log(account.id, "user.invited",
          actor_kind: "user",
          actor_id: actor_id,
          actor_label: "alice@example.com"
        )

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/audit")

      # The list's rows link only to the event detail (the per-cell actor
      # pivot moved to the detail page); the actor's NAME rides the meta line.
      assert html =~ "alice@example.com"
      # The facet panel is collapsed by default (the trail leads); the
      # toolbar toggle reveals it.
      refute html =~ ~s(name="from")
      html = lv |> element("button[phx-click='toggle_filters']") |> render_click()
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

      # The pivot's control is the facet panel now (the dismissable chip died):
      # a kind facet in the URL auto-opens it, the Actor picker renders with
      # the pivoted id, and rows scope to that actor.
      assert html =~ ~s(name="actor_id")
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

    # A relative WHEN cell must always pair with its OWN row. The bug: the
    # <time> carried phx-update="ignore" + a random id, so on a filter patch
    # morphdom reused a list row and left a neighbor's "2d ago" behind (a full
    # reload fixed it). The fix — no ignore, a row-stable id={"when-#{event.id}"}
    # — is locked here: every rendered <time> is keyed to its event and carries
    # that event's OWN datetime, before AND after a filter patch.
    test "each WHEN cell stays paired with its own event across a filter patch", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, connected} =
        Audit.log(account.id, "runner.connected",
          target_kind: "runner",
          target_label: "nomad-hvn03"
        )

      {:ok, policy} =
        Audit.log(account.id, "policy.updated",
          actor_kind: "user",
          actor_id: Ecto.UUID.generate(),
          actor_label: "fresh-actor"
        )

      {:ok, disconnected} =
        Audit.log(account.id, "runner.disconnected",
          target_kind: "runner",
          target_label: "nomad-hvn04"
        )

      # Push each to a distinct instant so a bled datetime is unambiguous.
      connected = shift_occurred_at(connected, -172_800)
      policy = shift_occurred_at(policy, -3_600)
      disconnected = shift_occurred_at(disconnected, -300)

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/audit")

      pairs = when_pairs(html)
      assert pairs["when-#{connected.id}"] == DateTime.to_iso8601(connected.occurred_at)
      assert pairs["when-#{policy.id}"] == DateTime.to_iso8601(policy.occurred_at)
      assert pairs["when-#{disconnected.id}"] == DateTime.to_iso8601(disconnected.occurred_at)
      # The hook owns the client render — the <time> is never a frozen, ignored
      # node (that freeze WAS the bug the whole task fixes).
      refute html =~ ~r/<time[^>]*phx-update/

      # Filter to runner events → the policy row (and its WHEN) drops; the two
      # kept rows still each pair with their OWN timestamp, not a neighbor's.
      # The live_patch is the exact interaction that surfaced the bleed.
      html = render_patch(lv, ~p"/app/#{account}/audit?target_kind=runner")
      pairs = when_pairs(html)
      refute Map.has_key?(pairs, "when-#{policy.id}")
      assert pairs["when-#{connected.id}"] == DateTime.to_iso8601(connected.occurred_at)
      assert pairs["when-#{disconnected.id}"] == DateTime.to_iso8601(disconnected.occurred_at)
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
          target_kind: "runner",
          target_label: "routine-runner"
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

      # A REAL runner row — the panel's Subject picker lists only live-resolvable
      # subjects, so a synthetic UUID would surface no picker.
      {:ok, runner} =
        Runner.Changeset.register(%{
          account_id: account.id,
          name: "pinned-runner",
          external_id: Ecto.UUID.generate(),
          group: "default"
        })
        |> Repo.insert()

      runner_id = runner.id

      {:ok, _} =
        Audit.log(account.id, "runner.connected",
          target_kind: "runner",
          target_id: runner_id,
          target_label: "pinned-runner"
        )

      {:ok, _} =
        Audit.log(account.id, "policy.updated",
          actor_kind: "user",
          actor_id: Ecto.UUID.generate(),
          actor_label: "unrelated-actor"
        )

      {:ok, _lv, html} =
        live(conn, ~p"/app/#{account}/audit?#{[target_kind: "runner", target_id: runner_id]}")

      # The pivot surfaces as the auto-opened facet panel's Subject picker
      # (highlighted + counted), and the rows scope to that subject.
      assert html =~ ~s(name="target_id")
      assert html =~ "pinned-runner"
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

    test "filtering by a bare actor_id (no kind) still narrows the list", %{conn: conn} do
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
               :binary.match(html, ~s(name="target_kind"))

      assert html =~ user.email
    end

    test "selecting a subject kind surfaces a picker of that kind's resolved subjects",
         %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      {:ok, _} = Audit.log(account.id, "user.invited", target_kind: "user", target_id: user.id)

      # No subject kind selected → no subject picker rendered.
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit")
      refute html =~ ~s(name="target_id")

      # Pick "user" → the picker appears with the resolved subject (the user's
      # email), right after its Subject trigger — same shape as the actor picker.
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit?target_kind=user")
      assert html =~ ~s(name="target_id")
      assert html =~ ~s(value="#{user.id}")
      assert html =~ user.email

      assert :binary.match(html, ~s(name="target_kind")) <
               :binary.match(html, ~s(name="target_id"))
    end

    # `approval_grant` and `policy` have no label resolver,
    # so their distinct-id options all resolve to nil and are rejected → the
    # dependent picker never renders (intentional; you filter those by Type).
    test "a subject kind with no label resolver surfaces no picker", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      # Real rows of the resolver-less kinds — the picker still must not appear.
      {:ok, _} =
        Audit.log(account.id, "approval.grant_revoked",
          target_kind: "approval_grant",
          target_id: Ecto.UUID.generate()
        )

      {:ok, _} =
        Audit.log(account.id, "policy.updated",
          target_kind: "policy",
          target_id: Ecto.UUID.generate()
        )

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit?target_kind=approval_grant")
      refute html =~ ~s(name="target_id")

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit?target_kind=policy")
      refute html =~ ~s(name="target_id")
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
    # invalidates the previously-picked target_id, dropping it from the URL.
    test "switching the subject kind drops the stale subject pick", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      {:ok, _} = Audit.log(account.id, "user.invited", target_kind: "user", target_id: user.id)

      {:ok, lv, _html} =
        live(conn, ~p"/app/#{account}/audit?target_kind=user&target_id=#{user.id}")

      lv
      |> form("#audit-events-filter", %{target_kind: "runner"})
      |> render_change()

      assert_patch(lv, ~p"/app/#{account}/audit?target_kind=runner")
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

    # same normalization for a crafted/blank target_id.
    test "a crafted or blank target_id is normalized, never a crash", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, _} =
        Audit.log(account.id, "user.invited", target_kind: "user", target_label: "real")

      {:ok, _lv, html} =
        live(conn, ~p"/app/#{account}/audit?target_kind=user&target_id=#{Ecto.UUID.generate()}")

      assert html =~ "No events match these filters."
      refute html =~ "real"

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit?target_id=")
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
    test "clearing the filters drops an actor pivot and restores the full feed", %{conn: conn} do
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

      # Land filtered to alice (kind + id — the pivot-link shape): bob's event
      # row is out. (Asserted by its LABEL — the string "bob" itself hides in
      # the Type combobox's data-combobox-* markup.)
      {:ok, lv, html} =
        live(conn, ~p"/app/#{account}/audit?#{[actor_kind: "user", actor_id: actor_a]}")

      refute html =~ "Policy updated"

      # Clear filters — the pivot drops with the facets, the full feed returns.
      html = lv |> element("a", "Clear filters") |> render_click()
      assert html =~ "Policy updated"
      refute html =~ ~s(name="actor_id")
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

      # actor_id is a pivot (chip), not a facet — the panel starts closed.
      # Open it, then change an unrelated filter (Outcome) — actor_id must
      # ride along.
      lv |> element("button[phx-click='toggle_filters']") |> render_click()

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
    test "a stale actor_id filters to the empty state, not a crash", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, _} = Audit.log(account.id, "user.invited", actor_kind: "user", actor_label: "real")

      stale = Ecto.UUID.generate()
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit?actor_id=#{stale}")

      assert html =~ "No events match these filters."
      refute html =~ "real"
    end

    test "an active preset chip highlights and a second click clears the range", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, _} = Audit.log(account.id, "user.invited", actor_kind: "user", actor_label: "x")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/audit")

      # First click arms the window: from lands in the URL + the chip lights up.
      html = lv |> element("button[phx-value-window='24h']") |> render_click()
      to = assert_patch(lv)
      params = URI.decode_query(URI.parse(to).query)
      assert params["window"] == "24h"
      assert Map.has_key?(params, "from")
      assert html =~ ~s(aria-pressed="true")

      # Second click clears the range entirely — the chip is a toggle.
      lv |> element("button[phx-value-window='24h']") |> render_click()
      to = assert_patch(lv)
      params = URI.decode_query(URI.parse(to).query || "")
      refute Map.has_key?(params, "window")
      refute Map.has_key?(params, "from")
      refute Map.has_key?(params, "to")
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
      {:ok, _} = Audit.log(account.id, "user.invited", target_kind: "user", target_label: "x")

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit?target_kind=runner")
      refute html =~ ~s(name="target_id")
    end

    # a system / scheduler / runbook actor has no
    # identifying row in another table, so it renders a clean label ("System")
    # with NO colon-id pair (which would read the meaningless "system: —").
    test "a system actor renders a clean label, not a kind:id pair", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, _} =
        Audit.log(account.id, "action_run.denied",
          actor_kind: "system",
          target_kind: "action_run",
          target_label: "linux.uptime"
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
          target_kind: "api_key",
          target_label: "ci-bot",
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
      assert html =~ ~p"/app/#{account}/agents"
    end

    test "parses bridge user agent into client + host + os posture fields", %{
      conn: conn,
      account: account
    } do
      {:ok, event} =
        Audit.log(account.id, "linux.uptime.run",
          actor_kind: "api_key",
          actor_label: "Claude Desktop",
          target_kind: "action_run",
          target_label: "linux.uptime",
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
          target_kind: "action_run",
          target_label: "nomad.job_status",
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

  # Empty an account's audit log so the genuinely-empty state can be tested — a
  # fresh account already carries its `account.created` / `user.signed_up` rows.
  # Building the queryable straight from the Query module is the sanctioned
  # test-fixture shape (§7).
  # {"when-<event_id>" => datetime attr} for every relative WHEN cell in the
  # rendered list — the pairing the cross-row bleed test asserts on.
  defp when_pairs(html) do
    ~r/<time id="(when-[^"]+)"[^>]*?datetime="([^"]+)"/
    |> Regex.scan(html)
    |> Map.new(fn [_, id, datetime] -> {id, datetime} end)
  end

  defp shift_occurred_at(event, seconds) do
    event
    |> Ecto.Changeset.change(occurred_at: DateTime.add(DateTime.utc_now(), seconds, :second))
    |> Repo.update!()
  end

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
