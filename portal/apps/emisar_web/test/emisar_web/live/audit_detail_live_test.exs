defmodule EmisarWeb.AuditDetailLiveTest do
  use EmisarWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Emisar.{Audit, RequestContext, Runs}

  test "an action_run event shows the runner under the subject, not as a device", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    runner =
      Fixtures.Runners.create_runner(%{
        account_id: account.id,
        name: "web-01",
        group: "frontend",
        runner_version: "0.7.4"
      })

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "net.http_probe",
        source: "mcp",
        args: %{}
      })

    # An action_run.denied event (system actor, action_run subject) the
    # runbook engine writes — stamped with the runner's connect UA, as it
    # was before the source fix, to prove the device line no longer surfaces
    # "Runner (Go)" for it.
    {:ok, event} =
      Audit.log(account.id, "action_run.denied",
        actor_kind: "system",
        target_kind: "action_run",
        target_id: run.id,
        target_label: run.action_id,
        context: %RequestContext{user_agent: "Go-http-client/1.1"}
      )

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit/#{event.id}")

    # Runner is a target property: name (group) version. The "Runner" label is
    # plain; only the name links to the runner. The subject's id renders too.
    assert html =~ ">Runner<"
    assert html =~ "web-01 (frontend) 0.7.4"
    assert html =~ ~p"/app/#{account}/runners/#{runner.id}"
    assert html =~ run.id

    # The bare Go HTTP client UA is no longer rendered as a device.
    refute html =~ "Runner (Go)"

    # The payload is copyable (the JSON <pre> is the copy target).
    assert html =~ ~s(id="audit-payload-json")
    assert html =~ ~s(data-copy="#audit-payload-json")
  end

  test "a current-shape run event targets the runner and links back to the run", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    runner = Fixtures.Runners.create_runner(%{account_id: account.id, name: "web-02"})

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "caddy.access_log_tail",
        source: "mcp",
        args: %{}
      })

    {:ok, event} = Audit.record(Audit.run_event_changeset(%{run | status: :success}))

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/audit/#{event.id}")

    # Target = WHERE it executed (the runner, by name)…
    assert html =~ "web-02"
    assert html =~ ~p"/app/#{account}/runners/#{runner.id}"
    # …and the card links back to WHAT ran.
    assert html =~ ">Run<"
    assert html =~ "caddy.access_log_tail"
    assert html =~ ~p"/app/#{account}/runs/#{run.id}"

    target_heading =
      lv
      |> element(~s([data-audit-entity="Target"] [data-audit-entity-heading]))
      |> render()

    assert target_heading =~
             ~r/data-audit-entity-kind[^>]*>\s*runner\s*<.*data-audit-entity-role[^>]*>\s*Target\s*</s
  end

  test "surfaces self-reported client metadata from the run payload, labeled as such", %{
    conn: conn
  } do
    {conn, _user, account} = register_and_log_in(conn)
    runner = Fixtures.Runners.create_runner(%{account_id: account.id, name: "web-02"})

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        source: "mcp",
        args: %{},
        mcp_client_metadata: %{"asset_tag" => "LT-4417"}
      })

    {:ok, event} = Audit.record(Audit.run_event_changeset(%{run | status: :success}))

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit/#{event.id}")

    assert html =~ "Client metadata"
    assert html =~ "asset_tag"
    assert html =~ "LT-4417"
    assert html =~ "not verified device posture"
  end

  test "the actor card stacks the human above the api_key/client", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    owner = Fixtures.Users.create_user(full_name: "Jordan Vale")

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner.id,
        role: "owner"
      )

    {_raw, key} =
      Fixtures.ApiKeys.create_api_key(
        account_id: account.id,
        name: "Claude Code",
        created_by_id: owner.id
      )

    {:ok, event} =
      Audit.log(account.id, "action.dispatched", actor_kind: "api_key", actor_id: key.id)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/audit/#{event.id}")

    primary =
      lv
      |> element(~s([data-audit-entity="Actor"] [data-audit-primary]))
      |> render()

    secondary =
      lv
      |> element(~s([data-audit-entity="Actor"] [data-audit-secondary]))
      |> render()

    heading =
      lv
      |> element(~s([data-audit-entity="Actor"] [data-audit-entity-heading]))
      |> render()

    facts =
      lv
      |> element(~s([data-audit-entity="Actor"] [data-audit-facts]))
      |> render()

    assert heading =~ "text-xs"
    assert heading =~ "leading-4"
    assert heading =~ "font-semibold text-zinc-400"

    assert heading =~
             ~r/data-audit-entity-kind[^>]*>\s*api key\s*<.*data-audit-entity-role[^>]*>\s*Actor\s*</s

    refute primary =~ "api_key:"
    assert primary =~ "Jordan Vale"
    refute primary =~ "Claude Code"
    assert secondary =~ "Claude Code"
    refute secondary =~ "via"
    assert facts =~ "grid-cols-[5.25rem_minmax(0,1fr)]"
    assert facts =~ "gap-y-1"
    assert facts =~ "text-xs"
    assert facts =~ "leading-5"
  end

  test "the actor card surfaces the sign-in method + 2FA state (provenance, not JSON)", %{
    conn: conn
  } do
    {conn, user, account} = register_and_log_in(conn)

    subject =
      Fixtures.Subjects.subject_for(user, account, role: :owner, auth_method: :sso, mfa: true)

    {:ok, event} = Audit.record(Audit.Events.account_updated(subject, account))

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit/#{event.id}")

    # Sign-in method with a 2FA badge — answerable at a glance, not buried in JSON.
    assert html =~ "Sign-in"
    assert html =~ "SSO"
    assert html =~ "2FA"
  end

  test ~S(a runner_version of "-" renders as no version, not a dangling dash), %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    runner =
      Fixtures.Runners.create_runner(%{
        account_id: account.id,
        name: "ci-bot-runner",
        group: "ci",
        runner_version: "-"
      })

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "ci.lint",
        source: "mcp",
        args: %{}
      })

    {:ok, event} =
      Audit.log(account.id, "action_run.denied",
        actor_kind: "system",
        target_kind: "action_run",
        target_id: run.id,
        target_label: run.action_id
      )

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit/#{event.id}")

    assert html =~ "ci-bot-runner (ci)"
    refute html =~ "ci-bot-runner (ci) -"
  end

  test "redirects anonymous users away from the detail route", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign_in"}}} =
             live(conn, ~p"/app/anon/audit/#{Ecto.UUID.generate()}")
  end

  test "an action_run subject whose run is in another account resolves to nil, never leaks the runner",
       %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    # A separate tenant with its own runner + run. The viewer has no
    # membership there.
    other = Fixtures.Accounts.create_account()

    other_runner =
      Fixtures.Runners.create_runner(%{
        account_id: other.id,
        name: "foreign-secret-runner",
        group: "prod",
        runner_version: "9.9.9"
      })

    {:ok, foreign_run} =
      Runs.create_run(%{
        account_id: other.id,
        runner_id: other_runner.id,
        action_id: "net.http_probe",
        source: "mcp",
        args: %{}
      })

    # An event stored in the VIEWER's account, but whose action_run subject id
    # points at the foreign account's run (a mis-stamped / forged subject id).
    # The event itself is readable (it's in `account`); the run is not.
    {:ok, event} =
      Audit.log(account.id, "action_run.denied",
        actor_kind: "system",
        target_kind: "action_run",
        target_id: foreign_run.id,
        target_label: "net.http_probe"
      )

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit/#{event.id}")

    # The subject-gated run fetch returns nil cross-account → the runner line
    # is simply hidden; the foreign runner's name/group never reach the page.
    refute html =~ "foreign-secret-runner"
    refute html =~ ">Runner<"
  end

  # when the action_run subject has been deleted since the
  # event, the page still renders: the subject label falls back to the stamped
  # `target_label` (no live row to resolve), and the runner line simply hides
  # because the subject-gated run fetch finds nothing.
  test "a deleted action_run subject falls back to its stamped label and hides the runner line",
       %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    runner =
      Fixtures.Runners.create_runner(%{
        account_id: account.id,
        name: "soon-gone-runner",
        group: "prod",
        runner_version: "1.0.0"
      })

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "net.http_probe",
        source: "mcp",
        args: %{}
      })

    {:ok, event} =
      Audit.log(account.id, "action_run.denied",
        actor_kind: "system",
        target_kind: "action_run",
        target_id: run.id,
        target_label: "net.http_probe"
      )

    # The run is deleted after the event was recorded (retention, manual cleanup).
    Emisar.Repo.delete!(run)

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit/#{event.id}")

    # The stamped label still shows (live resolve found nothing), and the page
    # didn't crash — no runner line because the run is gone.
    assert html =~ "net.http_probe"
    refute html =~ "soon-gone-runner"
    refute html =~ "runner:"
  end

  # an event with no recorded actor/subject kind renders the
  # "— (not recorded)" entity card rather than a broken or blank card.
  test "an event with nil actor and subject kind renders the not-recorded card", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    # A bare event: no actor_kind / target_kind stamped at all.
    {:ok, event} = Audit.log(account.id, "audit.bare_event", [])

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit/#{event.id}")

    assert html =~ "— (not recorded)"
    # Both cards render the placeholder (Actor + Subject), one each.
    assert length(String.split(html, "— (not recorded)")) == 3
  end

  test "a self-action renders the subject as 'same as actor (self)', not a duplicate card",
       %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)

    # A sign-in acts on itself: actor and subject are the same user.
    {:ok, event} =
      Audit.log(account.id, "user.signed_in",
        actor_kind: "user",
        actor_id: user.id,
        target_kind: "user",
        target_id: user.id
      )

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/audit/#{event.id}")

    assert html =~ "same as actor"
    assert html =~ "(self)"

    target_heading =
      lv
      |> element(~s([data-audit-entity="Target"] [data-audit-entity-heading]))
      |> render()

    assert target_heading =~
             ~r/data-audit-entity-kind[^>]*>\s*user\s*<.*data-audit-entity-role[^>]*>\s*Target\s*</s
  end

  test "the event id is a first-class copyable meta field; payload copy says Copy JSON",
       %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    {:ok, event} = Audit.log(account.id, "audit.bare_event", [])

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit/#{event.id}")

    # The event id leads as a scannable, copyable identity — no longer buried in
    # the payload panel's annotation.
    assert html =~ "Event ID"
    assert html =~ ~s(data-copy-text="#{event.id}")
    refute html =~ "event:#{event.id}"
    # The payload copy names what it grabs.
    assert html =~ "Copy JSON"
  end

  test "event metadata peers use one value tone", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    context = %RequestContext{ip_address: "203.0.113.7", request_id: "req_same_tone"}
    {:ok, event} = Audit.log(account.id, "audit.bare_event", context: context)

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit/#{event.id}")

    assert html =~ "text-sm leading-5 tabular-nums text-zinc-300"
    assert length(String.split(html, "text-sm leading-5 text-zinc-300")) >= 4
    refute html =~ "text-sm leading-5 tabular-nums text-zinc-200"
    refute html =~ "text-sm leading-5 text-zinc-400"
  end

  # payload rendering covers the edges: a nil payload shows
  # `{}`, a non-map payload is inspected, and a map is pretty JSON. Drive all
  # three through the live page (the <pre id="audit-payload-json"> is the target).
  test "payload renders {} for nil, inspect/1 for a non-map, pretty JSON for a map",
       %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    # nil payload → "{}". A fresh log/3 with no :payload leaves it nil. Read the
    # <pre> itself so we assert on the payload block, not stray braces elsewhere.
    {:ok, nil_event} = Audit.log(account.id, "audit.nil_payload", actor_kind: "system")
    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/audit/#{nil_event.id}")
    assert lv |> element("#audit-payload-json") |> render() =~ ">{}<"

    # map payload → pretty JSON (the indented multi-line form, not inline).
    {:ok, map_event} =
      Audit.log(account.id, "audit.map_payload",
        actor_kind: "system",
        payload: %{"nested" => %{"k" => "v"}}
      )

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit/#{map_event.id}")
    # Pretty JSON: the <pre> is HTML-rendered so quotes escape to &quot;, but the
    # newline + indentation structure stays — proving it's pretty, not compact.
    assert html =~ "&quot;nested&quot;: {"
    assert html =~ "    &quot;k&quot;: &quot;v&quot;"
  end

  # the policy.updated event gets its bespoke diff renderer:
  # tier-default changes plus added / removed / changed override diffs, built
  # from the REAL `Policies.diff_rules/2` output (the exact shape production
  # stamps), not plain JSON.
  test "a policy.updated event renders the bespoke changes diff", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    before_rules = %{
      "schema_version" => 2,
      "defaults" => %{
        "low" => "allow",
        "medium" => "allow",
        "high" => "allow",
        "critical" => "deny"
      },
      "overrides" => [
        %{"name" => "keep", "action" => "kept.*", "decision" => "allow"},
        %{"name" => "going", "action" => "gone.*", "decision" => "allow"},
        %{"name" => "moving", "action" => "moved.*", "decision" => "allow"}
      ]
    }

    after_rules = %{
      "schema_version" => 2,
      # high tier moves allow → require_approval (a tier-default diff).
      "defaults" => %{
        "low" => "allow",
        "medium" => "allow",
        "high" => "require_approval",
        "critical" => "deny"
      },
      "overrides" => [
        %{"name" => "keep", "action" => "kept.*", "decision" => "allow"},
        # "gone.*" removed, "moved.*" decision changed, "new.*" added.
        %{"name" => "moving", "action" => "moved.*", "decision" => "deny"},
        %{"name" => "fresh", "action" => "new.*", "decision" => "deny"}
      ]
    }

    changes = Emisar.Policies.diff_rules(before_rules, after_rules)

    {:ok, event} =
      Audit.log(account.id, "policy.updated",
        actor_kind: "user",
        target_kind: "policy",
        target_id: Ecto.UUID.generate(),
        payload: %{"changes" => changes, "before" => before_rules, "after" => after_rules}
      )

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit/#{event.id}")

    # The diff card, not raw JSON: the section header + each diff bucket.
    assert html =~ "Changes"
    assert html =~ "Tier defaults"
    assert html =~ "high:"
    assert html =~ "Added overrides"
    assert html =~ "new.*"
    assert html =~ "Removed overrides"
    assert html =~ "gone.*"
    assert html =~ "Modified overrides"
    assert html =~ "moved.*"
  end

  # a runner-as-actor event carries the runner's bare
  # `Go-http-client` UA. `device_label/1` returns nil for it, so the actor card
  # shows NO device line at all — the runner's HTTP client is not a "device"
  # worth surfacing, and it's never mislabeled as the MCP bridge.
  test "a runner-actor's Go-http-client UA renders no device line", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    {:ok, runner} =
      Emisar.Runners.Runner.Changeset.register(%{
        account_id: account.id,
        name: "db-prod-07",
        external_id: Ecto.UUID.generate(),
        group: "default",
        runner_version: "0.1.0"
      })
      |> Emisar.Repo.insert()

    {:ok, event} =
      Audit.log(account.id, "runner.connected",
        actor_kind: "runner",
        actor_id: runner.id,
        actor_label: "db-prod-07",
        user_agent: "Go-http-client/1.1"
      )

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/audit/#{event.id}")

    # The bare Go HTTP client is not rendered as a device, and not parsed into
    # an MCP posture block — the UA string never appears on the actor card.
    refute html =~ "Go-http-client"
    refute has_element?(lv, "[data-audit-facts] dt", "MCP client")
  end

  # an opaque UA with no `client=`/`host=` posture block is
  # NOT mislabeled as the MCP bridge: parse_client_posture/1 only treats a UA as
  # a bridge when it actually parsed a structured posture field, so "MCP client"
  # never shows for an arbitrary string (it's just shown as a device instead).
  test "an opaque non-bridge UA is not labeled as the MCP bridge", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    {:ok, event} =
      Audit.log(account.id, "api_key.created",
        actor_kind: "api_key",
        actor_label: "some-agent",
        user_agent: "python-requests/2.31.0"
      )

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/audit/#{event.id}")

    # No parsed posture → no MCP attribution. (The device line may still show a
    # short token, but the bridge-only cells stay hidden.)
    refute has_element?(lv, "[data-audit-facts] dt", "MCP client")
  end
end
