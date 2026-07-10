defmodule EmisarWeb.RunNewLiveTest do
  @moduledoc """
  The run-dispatch form's inputs are generated from the selected action's
  argument spec. Bad or missing args must render inline under the offending
  field (rose border, message beneath it), not in a flash banner.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Auth.Subject
  alias Emisar.{Repo, Runners, Runs}

  defp action_with_required_arg(account) do
    runner = Fixtures.Runners.create_runner(account_id: account.id)

    action =
      Fixtures.Catalog.create_action(
        runner: runner,
        action_id: "linux.tail_log",
        args_schema: %{
          "args" => [
            %{
              "name" => "path",
              "type" => "string",
              "required" => true,
              "description" => "Absolute path to the log file"
            }
          ]
        }
      )

    {runner, action}
  end

  # An action declaring two integer args, so a single submit can exercise
  # both the bad-integer parse error and the all-errors-at-once collection.
  defp action_with_two_int_args(account) do
    runner = Fixtures.Runners.create_runner(account_id: account.id)

    action =
      Fixtures.Catalog.create_action(
        runner: runner,
        action_id: "linux.kill_pid",
        risk: "low",
        args_schema: %{
          "args" => [
            %{"name" => "pid", "type" => "integer", "required" => true, "description" => "PID"},
            %{
              "name" => "signal",
              "type" => "integer",
              "required" => true,
              "description" => "Signal number"
            }
          ]
        }
      )

    {runner, action}
  end

  test "missing required arg renders inline on the field, not in a flash", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    {runner, action} = action_with_required_arg(account)

    {:ok, lv, _html} =
      live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    # Required `path` left blank; reason is filled so we exercise the arg
    # validation, not the reason guard.
    html =
      lv
      |> form("#dispatch_form", %{
        "args" => %{"path" => ""},
        "reason" => "checking the access log"
      })
      |> render_submit()

    # Inline field error rendered by <.input>/<.error> under the `path` input…
    assert html =~ "path is required"
    # …and not the old humanized flash banner.
    refute html =~ "Invalid:"
  end

  # the action-context panel (title + description) and the
  # meta strip (risk / kind / pack) render, with one arg input per declared arg
  # plus the reason textarea.
  test "renders the action context panel + meta strip + an input per arg", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    runner = Fixtures.Runners.create_runner(account_id: account.id)

    action =
      Fixtures.Catalog.create_action(
        runner: runner,
        action_id: "linux.tail_log",
        title: "Tail a log file",
        description: "Streams the tail of a log on the host.",
        pack_id: "linux-core",
        kind: "exec",
        risk: "medium",
        args_schema: %{
          "args" => [
            %{
              "name" => "path",
              "type" => "string",
              "required" => true,
              "description" => "Log path"
            }
          ]
        }
      )

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    # Context panel: title + description prose.
    assert html =~ "Tail a log file"
    assert html =~ "Streams the tail of a log on the host."

    # Meta strip: risk / kind / pack.
    assert html =~ "Risk"
    assert html =~ "Kind"
    assert html =~ "exec"
    assert html =~ "Pack"
    assert html =~ "linux-core"

    # One input for the declared `path` arg, plus the reason textarea.
    assert has_element?(lv, "input[name=\"args[path]\"]")
    assert has_element?(lv, "textarea[name=\"reason\"]")
  end

  # Side effects render inside the About panel — amber only when the action
  # can mutate (risk above :low), so amber keeps meaning "caution". Backtick
  # spans in pack text render as inline mono, never literal backticks.
  test "renders the side-effects list, amber for a risky action", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    runner = Fixtures.Runners.create_runner(account_id: account.id)

    action =
      Fixtures.Catalog.create_action(
        runner: runner,
        action_id: "linux.reboot",
        risk: "high",
        side_effects: ["restarts the host", "drops all active connections"]
      )

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    assert html =~ "Side effects"
    assert html =~ "restarts the host"
    assert html =~ "drops all active connections"
    assert html =~ "text-amber-300"
  end

  test "a read-only action's side effects stay neutral and backticks render as code", %{
    conn: conn
  } do
    {conn, _user, account} = register_and_log_in(conn)
    runner = Fixtures.Runners.create_runner(account_id: account.id)

    action =
      Fixtures.Catalog.create_action(
        runner: runner,
        action_id: "linux.arp_neighbors",
        risk: "low",
        side_effects: ["One `ip` invocation. Read-only."]
      )

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    assert html =~ "Side effects"
    assert html =~ ~r{<code[^>]*>\s*ip\s*</code>}
    refute html =~ "One `ip` invocation"
    refute html =~ "text-amber-300"
  end

  test "an enforcing runner replaces the Dispatch button with a signed-only notice", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    runner =
      Fixtures.Runners.create_runner(
        account_id: account.id,
        enforce_signatures: true,
        connected?: true
      )

    action = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime")

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    assert html =~ "Signed dispatch only"
    assert html =~ "run it from your MCP client"
    # No Dispatch submit — the run would be refused at the runner.
    refute html =~ "Dispatch to"
  end

  test "live validation surfaces an inline error once the field is touched", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    {runner, action} = action_with_required_arg(account)

    {:ok, lv, _html} =
      live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    html =
      lv
      |> form("#dispatch_form", %{"args" => %{"path" => ""}, "reason" => ""})
      |> render_change()

    assert html =~ "path is required"
    refute html =~ "Invalid:"
  end

  test "an unknown action bounces back to the runner page", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    runner = Fixtures.Runners.create_runner(account_id: account.id)

    assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
             live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/no.such_action")

    assert to == ~p"/app/#{account}/runners/#{runner.id}"
    assert flash["error"] == "Action not found."
  end

  # A blank reason is a validation of the operator's own input, so it renders
  # inline under the reason field (rose <.error>), never as a top-of-page flash.
  test "a blank reason renders inline at the field, not in a flash", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    _ = Fixtures.Policies.create_policy(account_id: account.id, created_by_id: user.id)
    {runner, action} = action_with_required_arg(account)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    lv
    |> form("#dispatch_form", %{"args" => %{"path" => "/var/log/app.log"}, "reason" => "  "})
    |> render_submit()

    # The message is the inline field error inside the form, not the flash banner.
    assert has_element?(lv, "#dispatch_form p.text-rose-400", "Reason is required")
    refute has_element?(lv, "#flash-error", "Reason is required")
    assert {:ok, [], _} = Runs.list_recent_runs(owner_subject(user, account), limit: 50)
  end

  test "a valid dispatch navigates to the run detail page", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    _ = Fixtures.Policies.create_policy(account_id: account.id, created_by_id: user.id)
    {runner, action} = action_with_required_arg(account)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    lv
    |> form("#dispatch_form", %{
      "args" => %{"path" => "/var/log/app.log"},
      "reason" => "tailing the access log"
    })
    |> render_submit()

    {path, _flash} = assert_redirect(lv)
    assert path =~ ~r{^/app/#{account.slug}/runs/[0-9a-f-]+$}
  end

  test "a policy denial is a flash, and no run is dispatched", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)

    # Deny everything at every risk tier.
    _ =
      Fixtures.Policies.create_policy(
        account_id: account.id,
        created_by_id: user.id,
        rules: %{
          "defaults" => %{
            "low" => "deny",
            "medium" => "deny",
            "high" => "deny",
            "critical" => "deny"
          }
        }
      )

    {runner, action} = action_with_required_arg(account)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    html =
      lv
      |> form("#dispatch_form", %{
        "args" => %{"path" => "/var/log/app.log"},
        "reason" => "should be denied"
      })
      |> render_submit()

    assert html =~ "Denied by policy"
  end

  test "a viewer cannot dispatch at the event level", %{conn: conn} do
    {_owner_conn, _owner, account} = register_and_log_in(conn)
    {runner, action} = action_with_required_arg(account)

    viewer = Fixtures.Users.create_user()

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: viewer.id,
        role: "viewer"
      )

    {:ok, lv, _html} =
      build_conn()
      |> log_in_user(viewer)
      |> live(~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    # The form's inputs are hidden for a viewer — submit a raw payload to
    # prove the EVENT-level gate (IL-15) holds regardless of the rendered UI.
    html =
      lv
      |> form("#dispatch_form", %{})
      |> render_submit(%{
        "args" => %{"path" => "/var/log/app.log"},
        "reason" => "viewer trying anyway"
      })

    assert html =~ "You don&#39;t have permission to do that."
  end

  test "a high-risk action's dispatch button asks for confirmation", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    runner = Fixtures.Runners.create_runner(account_id: account.id)

    action =
      Fixtures.Catalog.create_action(runner: runner, action_id: "linux.reboot", risk: "critical")

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    assert has_element?(lv, "button[data-confirm]")
    assert render(lv) =~ "runs on the host immediately"
  end

  test "a high-risk confirm folds in the entered args (the blast radius)", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    runner = Fixtures.Runners.create_runner(account_id: account.id)

    action =
      Fixtures.Catalog.create_action(
        runner: runner,
        action_id: "linux.tail_log",
        risk: "high",
        args_schema: %{
          "args" => [
            %{
              "name" => "path",
              "type" => "string",
              "required" => true,
              "description" => "Log path"
            }
          ]
        }
      )

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    # Type a path → the confirm must echo it so the operator confirms WHAT
    # runs (which file), not just the action name.
    html =
      lv
      |> form("#dispatch_form", %{"args" => %{"path" => "/var/log/auth.log"}, "reason" => "x"})
      |> render_change()

    assert html =~ "path: /var/log/auth.log"
  end

  test "a low-risk action's dispatch button does not confirm", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    runner = Fixtures.Runners.create_runner(account_id: account.id)

    action =
      Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    # The button names the TARGET — the last glance binds action + host.
    assert has_element?(lv, "button", "Dispatch to #{runner.name}")
    refute has_element?(lv, "button[data-confirm]")
  end

  test "an offline runner warns the run will queue", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
    action = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime")

    # The runner is only looked up on the connected render, so assert
    # against render/1.
    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")
    html = render(lv)

    assert html =~ "Runner offline"
    assert html =~ "queues as"
  end

  test "a viewer sees a note instead of the dispatch button", %{conn: conn} do
    {_owner_conn, _owner, account} = register_and_log_in(conn)
    runner = Fixtures.Runners.create_runner(account_id: account.id)
    action = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime")

    viewer = Fixtures.Users.create_user()

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: viewer.id,
        role: "viewer"
      )

    {:ok, lv, html} =
      build_conn()
      |> log_in_user(viewer)
      |> live(~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    refute has_element?(lv, "button", "Dispatch to")
    assert html =~ "Your role can&#39;t dispatch runs"
  end

  # -- dispatch denial / abuse flashes ---------------------------------
  #
  # The engine maps each refusal atom to a specific flash and (except the
  # two terminal-state cases) creates NO run + stays on the form. The
  # action is advertised at mount so the page loads; the runner/pack/scope
  # state at SUBMIT time is what trips each gate (re-checked server-side,
  # never trusted from mount).

  defp submit_dispatch(lv, args \\ %{"path" => "/var/log/app.log"}, reason \\ "doing the thing") do
    lv
    |> form("#dispatch_form", %{"args" => args, "reason" => reason})
    |> render_submit()
  end

  # a runner that
  # no longer resolves in the account (soft-deleted between mount and submit, the
  # same `runner_in_account` path a cross-account/unresolvable id takes) →
  # :runner_not_found flash, no run. That gate runs before the action/pack checks,
  # so the deleted runner is refused here. (T17/T08 = the cross-account framing;
  # T05/T02 = "dispatch to a runner id that doesn't resolve" — one and the same
  # server check and flash.)
  test "a runner that's gone at dispatch time → :runner_not_found flash, no run", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    _ = Fixtures.Policies.create_policy(account_id: account.id, created_by_id: user.id)
    {runner, action} = action_with_required_arg(account)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    # Soft-delete the runner after mount: the catalog action row stays, so
    # `runner_in_account` is the gate that fires.
    {:ok, _} = runner |> Runners.Runner.Changeset.delete() |> Repo.update()

    html = submit_dispatch(lv)

    assert html =~ "Runner not found in this account."
    assert {:ok, [], _} = Runs.list_recent_runs(owner_subject(user, account), limit: 50)
  end

  # an action de-advertised between mount and
  # submit (its catalog row dropped — the runner stays registered) → :action_not_found
  # flash, no run. `require_runner`/`runner_in_account` pass (the runner still
  # exists), so `fetch_advertised_action` is the gate that fires; the flash points
  # the operator at reloading for a current action.
  test "an action gone at dispatch time → :action_not_found flash, no run", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    _ = Fixtures.Policies.create_policy(account_id: account.id, created_by_id: user.id)
    {runner, action} = action_with_required_arg(account)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    # De-advertise the action after mount: the runner row stays, so the
    # action-resolution step (not the runner check) is what refuses.
    Repo.delete!(action)

    html = submit_dispatch(lv)

    assert html =~ "no longer advertises that action"
    assert {:ok, [], _} = Runs.list_recent_runs(owner_subject(user, account), limit: 50)
  end

  # an operator whose membership is scoped
  # to a DIFFERENT runner group → :runner_out_of_scope flash, no run. The scope
  # is re-checked at dispatch (`requested_by_membership_id`), so a grant revoked
  # mid-session still bites.
  test "a runner outside the operator's scope → :runner_out_of_scope flash, no run", %{conn: conn} do
    {_owner_conn, owner, account} = register_and_log_in(conn)
    {runner, action} = action_with_required_arg(account)
    _ = Fixtures.Policies.create_policy(account_id: account.id, created_by_id: owner.id)

    operator = Fixtures.Users.create_user()

    membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: operator.id,
        role: "operator"
      )

    # Scope the operator to a group that ISN'T this runner's ("default").
    {:ok, _} =
      Runners.replace_runner_scopes(
        membership,
        [{"group", "locked-out"}],
        owner_subject(owner, account)
      )

    {:ok, lv, _html} =
      build_conn()
      |> log_in_user(operator)
      |> live(~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    html = submit_dispatch(lv)

    assert html =~ "outside your access scope"
    assert {:ok, [], _} = Runs.list_recent_runs(owner_subject(owner, account), limit: 50)
  end

  # an action from an untrusted (pending)
  # pack version → :pack_untrusted flash directing to Packs, no run. The action
  # is advertised so mount loads; `check_pack_trust` refuses at dispatch.
  test "an untrusted pack → :pack_untrusted flash, no run", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    _ = Fixtures.Policies.create_policy(account_id: account.id, created_by_id: user.id)
    runner = Fixtures.Runners.create_runner(account_id: account.id)

    # A custom (no-baseline) pack advertises an action and lands :pending —
    # the runner advertises a hash no operator has trusted.
    {:ok, _} =
      Emisar.Catalog.observe_state(runner, %{
        "hostname" => "h",
        "version" => "0.1",
        "labels" => %{},
        "packs" => %{"custom" => %{"version" => "1.0", "hash" => "sha256:NOPE"}},
        "actions" => [
          %{
            "id" => "custom.do",
            "pack_id" => "custom",
            "title" => "Do",
            "kind" => "exec",
            "risk" => "low",
            "args" => []
          }
        ]
      })

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/custom.do")

    html = submit_dispatch(lv, %{}, "running the custom action")

    assert html =~ "untrusted version of the action"
    assert html =~ "Packs page"
    assert {:ok, [], _} = Runs.list_recent_runs(owner_subject(user, account), limit: 50)
  end

  # an enforcing (signed-only) runner hides the Dispatch
  # button, but a FORCED submit must still be refused server-side with the
  # :runner_requires_attestation flash (the portal can't sign).
  test "a forced submit to a signed-only runner → :runner_requires_attestation flash", %{
    conn: conn
  } do
    {conn, user, account} = register_and_log_in(conn)
    _ = Fixtures.Policies.create_policy(account_id: account.id, created_by_id: user.id)

    runner =
      Fixtures.Runners.create_runner(
        account_id: account.id,
        enforce_signatures: true,
        connected?: true
      )

    action = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime")

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    # The button is replaced by a signed-only notice…
    refute html =~ "Dispatch to runner"

    # …but the form still exists; forcing the submit reaches the handler,
    # which gates on the runner's attestation requirement.
    html = submit_dispatch(lv, %{}, "forcing it anyway")

    assert html =~ "only accepts signed runs from an MCP client"
    assert {:ok, [], _} = Runs.list_recent_runs(owner_subject(user, account), limit: 50)
  end

  # a policy deny is a flash AND the engine records the
  # attempt as a :denied run (so operators see it in audit); the form does not
  # navigate to a run page.
  test "a policy deny flashes and the run is recorded as :denied (no navigate)", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)

    _ =
      Fixtures.Policies.create_policy(
        account_id: account.id,
        created_by_id: user.id,
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

    {runner, action} = action_with_required_arg(account)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    html = submit_dispatch(lv, %{"path" => "/var/log/app.log"}, "should be denied")

    assert html =~ "Denied by policy"

    # The engine writes the attempt as a :denied run, and the form stayed put
    # (no redirect to a run page).
    assert {:ok, [%{status: :denied, policy_decision: "deny"}], _} =
             Runs.list_recent_runs(owner_subject(user, account), limit: 50)
  end

  # an approval-required action creates a
  # :pending_approval run and navigates to its run page (the approval banner
  # lives there), unlike the deny path which stays on the form.
  test "an approval-required action creates a :pending_approval run and navigates", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)

    _ =
      Fixtures.Policies.create_policy(
        account_id: account.id,
        created_by_id: user.id,
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

    {runner, action} = action_with_required_arg(account)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    submit_dispatch(lv, %{"path" => "/var/log/app.log"}, "needs sign-off")

    # Navigates to the created run's page…
    {path, _flash} = assert_redirect(lv)
    assert path =~ ~r{^/app/#{account.slug}/runs/[0-9a-f-]+$}

    # …and that run is parked as :pending_approval.
    assert {:ok, [%{status: :pending_approval}], _} =
             Runs.list_recent_runs(owner_subject(user, account), limit: 50)
  end

  # `dispatch_run_permission` is owner/admin/operator/api_client;
  # a `:runner` subject (the runner socket's identity) holds only view_runs, so it
  # can never dispatch. The form only ever builds a user subject, so this asserts
  # the underlying capability predicate the gate relies on.
  test "a :runner subject is excluded from the dispatch permission", %{conn: conn} do
    {_conn, _user, account} = register_and_log_in(conn)
    runner = Fixtures.Runners.create_runner(account_id: account.id)

    runner_subject = Subject.for_runner(runner, account)

    refute Runs.subject_can_dispatch_run?(runner_subject)
  end

  # a non-numeric integer arg renders an
  # inline parse error on the field ("not an integer"), not a flash, and no run
  # is dispatched.
  test "a bad integer arg renders an inline error on the field, no run", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    _ = Fixtures.Policies.create_policy(account_id: account.id, created_by_id: user.id)
    {runner, action} = action_with_two_int_args(account)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    html =
      lv
      |> form("#dispatch_form", %{
        "args" => %{"pid" => "not-a-number", "signal" => "9"},
        "reason" => "killing the stuck process"
      })
      |> render_submit()

    assert html =~ "not an integer"
    refute html =~ "Dispatch failed"
    assert {:ok, [], _} = Runs.list_recent_runs(owner_subject(user, account), limit: 50)
  end

  # several bad args are collected and
  # rendered inline in ONE pass, not just the first: a blank required `pid`
  # ("pid is required") AND a non-numeric `signal` ("not an integer") both show.
  test "every bad arg is reported at once, not just the first", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    {runner, action} = action_with_two_int_args(account)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    html =
      lv
      |> form("#dispatch_form", %{
        "args" => %{"pid" => "", "signal" => "nope"},
        "reason" => "x"
      })
      |> render_submit()

    # Both fields' errors render — the missing-required one AND the bad-integer
    # one — proving the coercion collects every error, not just the first.
    assert html =~ "pid is required"
    assert html =~ "not an integer"
  end

  # a zero-arg action's phx-change payload has no "args"
  # key; validate must default to the existing params, not FunctionClauseError.
  test "validate on a zero-arg action (no args key) doesn't crash", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    runner = Fixtures.Runners.create_runner(account_id: account.id)

    action =
      Fixtures.Catalog.create_action(
        runner: runner,
        action_id: "linux.uptime",
        args_schema: %{"args" => []}
      )

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    # Only `reason` in the change payload — no "args" key at all.
    html = lv |> form("#dispatch_form", %{"reason" => "just checking"}) |> render_change()

    # Survives + re-renders the form (the reason value round-trips).
    assert html =~ "Reason"
    assert html =~ "just checking"
  end

  # (IL-14) — the schemaless arg form is backed
  # by raw string-keyed params (`to_form(params, as: "args")`), so an arbitrary
  # runner/pack-advertised arg name never becomes an atom. Asserting on a name
  # that is NOT an existing atom proves no atom is created on the form path.
  test "the arg form keeps arbitrary arg names as strings — no String.to_atom (IL-14)", %{
    conn: conn
  } do
    {conn, _user, account} = register_and_log_in(conn)
    runner = Fixtures.Runners.create_runner(account_id: account.id)

    # A deliberately weird arg name that is very unlikely to already exist as an
    # atom in the VM. `to_existing_atom` raising on it AFTER the form renders
    # proves the form path (mount + validate) never minted it.
    arg_name = "zztop_#{System.unique_integer([:positive])}_arg"

    action =
      Fixtures.Catalog.create_action(
        runner: runner,
        action_id: "custom.weird",
        args_schema: %{
          "args" => [
            %{"name" => arg_name, "type" => "string", "required" => false, "description" => "x"}
          ]
        }
      )

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    # The arg renders as a string-keyed form field…
    assert html =~ arg_name

    # …and exercising phx-change with that string key doesn't create the atom.
    lv
    |> form("#dispatch_form", %{"args" => %{arg_name => "value"}, "reason" => ""})
    |> render_change()

    assert_raise ArgumentError, fn -> String.to_existing_atom(arg_name) end
  end
end
