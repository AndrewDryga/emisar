defmodule EmisarWeb.PoliciesPerformanceLiveTest do
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Fixtures, Policies}

  setup %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)

    %{
      conn: conn,
      user: user,
      account: account,
      subject: Fixtures.Subjects.subject_for(user, account)
    }
  end

  test "initial page retains only 25 rule-free summaries and opens one editor on demand", %{
    conn: conn,
    account: account,
    user: user
  } do
    policies =
      for i <- 1..28,
          do: scoped(account, user, "group-#{String.pad_leading(to_string(i), 2, "0")}")

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/policies")
    state = assigns(lv)
    assert length(state.summaries) == 25
    assert state.rulesets == []
    refute Map.has_key?(state, :catalog_index)
    refute Map.has_key?(state, :runners)
    refute Enum.any?(state.summaries, &Map.has_key?(&1, :rules))
    refute html =~ "Save ruleset"
    render_click(lv, "open_ruleset", %{"uid" => hd(policies).id})
    assert [%{uid: uid, policy: %{rules: rules}}] = assigns(lv).rulesets
    assert uid == hd(policies).id
    assert rules == hd(policies).rules
    lv |> element("#saved-policies-pager a", "Next") |> render_click()
    assert length(assigns(lv).summaries) == 3
    assert assigns(lv).rulesets == []
  end

  test "dirty saved editors, the account draft and a new draft survive paging and sibling save",
       %{account: account, conn: conn, user: user} do
    [first, second, clean | _] =
      for i <- 1..28,
          do: scoped(account, user, "group-#{String.pad_leading(to_string(i), 2, "0")}")

    Fixtures.Runners.create_runner(account_id: account.id, group: "free", connected?: false)
    {:ok, lv, _} = live(conn, ~p"/app/#{account}/policies")

    for policy <- [first, second, clean],
        do: render_click(lv, "open_ruleset", %{"uid" => policy.id})

    for uid <- ["account", first.id, second.id] do
      render_hook(lv, "form_change", %{
        "editor" => uid,
        "policy" => %{"defaults" => %{"low" => "deny"}}
      })
    end

    render_click(lv, "add_ruleset", %{})
    new_uid = List.last(assigns(lv).rulesets).uid
    render_hook(lv, "set_target", %{"uid" => new_uid, "target" => "group:free"})
    lv |> element("#saved-policies-pager a", "Next") |> render_click()
    assert Enum.map(assigns(lv).rulesets, & &1.uid) == [first.id, second.id, new_uid]
    assert assigns(lv).account.defaults["low"] == "deny"
    render_hook(lv, "save", %{"editor" => first.id})
    assert Enum.map(assigns(lv).rulesets, & &1.uid) == [first.id, second.id, new_uid]
    assert editor(lv, second.id).defaults["low"] == "deny"
    assert editor(lv, new_uid).scope_value == "free"
    assert length(assigns(lv).summaries) == 3
    settle(lv)
  end

  test "target search is paged, preserves an off-search selection and refreshes taken status after sibling save",
       %{account: account, conn: conn} do
    runners =
      for i <- 1..27 do
        Fixtures.Runners.create_runner(
          account_id: account.id,
          name: "runner-#{String.pad_leading(to_string(i), 2, "0")}",
          group: "fleet",
          connected?: false
        )
      end

    target = List.last(runners)
    {:ok, lv, _} = live(conn, ~p"/app/#{account}/policies")
    render_click(lv, "add_ruleset", %{})
    uid = List.last(assigns(lv).rulesets).uid
    assert length(editor(lv, uid).target_options) == 25
    render_hook(lv, "search_targets", %{"uid" => uid, "search" => target.name})
    render_hook(lv, "set_target", %{"uid" => uid, "target" => "runner:#{target.id}"})
    render_hook(lv, "search_targets", %{"uid" => uid, "search" => "runner-01"})
    assert has_element?(lv, "#policy-target-#{uid} option[value='runner:#{target.id}'][selected]")
    render_click(lv, "add_ruleset", %{})
    sibling = List.last(assigns(lv).rulesets).uid
    render_hook(lv, "search_targets", %{"uid" => sibling, "search" => target.name})

    assert has_element?(
             lv,
             "#policy-target-#{sibling} option[value='runner:#{target.id}'][disabled]"
           )

    render_hook(lv, "save", %{"editor" => uid})

    assert has_element?(
             lv,
             "#policy-target-#{sibling} option[value='runner:#{target.id}'][disabled]"
           )

    assert editor(lv, sibling).target_search == target.name
    settle(lv)
  end

  test "invalid target searches preserve the last valid search, selected target and draft", %{
    account: account,
    conn: conn
  } do
    target =
      Fixtures.Runners.create_runner(
        account_id: account.id,
        name: "database",
        connected?: false
      )

    {:ok, lv, _} = live(conn, ~p"/app/#{account}/policies")
    render_click(lv, "add_ruleset", %{})
    uid = List.last(assigns(lv).rulesets).uid
    render_hook(lv, "search_targets", %{"uid" => uid, "search" => "database"})
    render_hook(lv, "set_target", %{"uid" => uid, "target" => "runner:#{target.id}"})

    render_hook(lv, "form_change", %{
      "editor" => uid,
      "policy" => %{"defaults" => %{"low" => "deny"}}
    })

    for search <- ["db\0", <<255>>, String.duplicate("a", 513), nil, []] do
      html = render_hook(lv, "search_targets", %{"uid" => uid, "search" => search})
      assert html =~ "Use valid text without null characters, up to 512 bytes."
      assert editor(lv, uid).target_search == "database"
      assert editor(lv, uid).scope_value == target.id
      assert editor(lv, uid).defaults["low"] == "deny"

      assert has_element?(
               lv,
               "#policy-target-#{uid} option[value='runner:#{target.id}'][selected]"
             )
    end

    html = render_hook(lv, "search_targets", %{"uid" => uid, "search" => "missing"})
    refute html =~ "Use valid text without null characters, up to 512 bytes."
    assert editor(lv, uid).target_search == "missing"
    assert editor(lv, uid).scope_value == target.id
    assert editor(lv, uid).defaults["low"] == "deny"
    settle(lv)
  end

  test "saved targets cannot be retargeted and foreign editor ids cannot be opened", %{
    conn: conn,
    account: account,
    user: user
  } do
    policy = scoped(account, user, "db")
    foreign = Fixtures.Policies.create_policy(scope_type: :group, scope_value: "private")
    {:ok, lv, _} = live(conn, ~p"/app/#{account}/policies")
    render_click(lv, "open_ruleset", %{"uid" => policy.id})
    render_hook(lv, "set_target", %{"uid" => policy.id, "target" => "group:other"})
    assert editor(lv, policy.id).scope_value == "db"
    render_hook(lv, "open_ruleset", %{"uid" => foreign.id})
    assert Enum.map(assigns(lv).rulesets, & &1.uid) == [policy.id]
    refute render(lv) =~ "private"
    settle(lv)
  end

  test "obsolete timers do not run previews and rapid edits fold into one current result", %{
    account: account,
    conn: conn
  } do
    runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)

    Fixtures.Catalog.create_action(
      runner: runner,
      pack_id: "test",
      action_id: "db.read",
      risk: "low"
    )

    {:ok, lv, _} = live(conn, ~p"/app/#{account}/policies")
    settle(lv)
    old = assigns(lv).account.preview_generation

    for decision <- ["allow", "require_approval", "deny"] do
      render_hook(lv, "form_change", %{
        "editor" => "account",
        "policy" => %{"defaults" => %{"low" => decision}}
      })
    end

    current = assigns(lv).account.preview_generation
    send(lv.pid, {:preview_due, "account", old})
    render(lv)
    assert assigns(lv).account.preview_generation == current
    assert assigns(lv).account.preview == :pending
    settle(lv)
    assert {:ok, preview} = assigns(lv).account.preview
    assert preview.outcome["deny"].count == 1
    send(lv.pid, {:preview_due, "account", current})
    render(lv)
    assert assigns(lv).preview_active == nil
    assert assigns(lv).preview_queue == []
  end

  test "closing an active editor cooperatively cancels it and starts the already queued editor",
       %{conn: conn, account: account, user: user} do
    first = scoped(account, user, "a")
    second = scoped(account, user, "b")
    {:ok, lv, _} = live(conn, ~p"/app/#{account}/policies")
    settle(lv)
    hold_next_preview(account.id)
    render_click(lv, "open_ruleset", %{"uid" => first.id})
    assert_receive {:held_preview, task}, 2_000
    render_click(lv, "open_ruleset", %{"uid" => second.id})
    flush_timer(lv, second.id)
    assert assigns(lv).preview_queue == [second.id]
    render_click(lv, "close_ruleset", %{"uid" => first.id})
    assert Process.alive?(task)
    send(task, :continue_preview)
    settle(lv)
    assert Enum.map(assigns(lv).rulesets, & &1.uid) == [second.id]
    assert {:ok, %{total: 0}} = editor(lv, second.id).preview
    assert assigns(lv).preview_active == nil
    assert assigns(lv).preview_queue == []
  end

  test "a held preview does not overwrite a new edit or break its save", %{
    conn: conn,
    account: account
  } do
    {:ok, lv, _} = live(conn, ~p"/app/#{account}/policies")
    settle(lv)
    hold_next_preview(account.id)
    render_click(lv, "retry_preview", %{"editor" => "account"})
    assert_receive {:held_preview, task}, 2_000

    render_hook(lv, "form_change", %{
      "editor" => "account",
      "policy" => %{"defaults" => %{"low" => "deny"}}
    })

    render_hook(lv, "save", %{"editor" => "account"})
    assert Process.alive?(task)
    send(task, :continue_preview)
    settle(lv)
    assert assigns(lv).account.defaults["low"] == "deny"
    assert Policies.peek_policy_for_account(account.id).rules["defaults"]["low"] == "deny"
    assert {:ok, _} = assigns(lv).account.preview
  end

  test "failed default state has no fabricated editor and refuses dependent forged events", %{
    conn: conn,
    account: account
  } do
    {:ok, lv, _} = live(conn, ~p"/app/#{account}/policies")
    settle(lv)

    failed = %Phoenix.LiveView.Socket{
      assigns: %{assigns(lv) | account: nil, account_error?: true}
    }

    for event <- ~w(add_ruleset open_ruleset set_target save form_change retry_preview) do
      assert {:noreply, ^failed} =
               EmisarWeb.PoliciesLive.handle_event(
                 event,
                 %{"uid" => "forged", "editor" => "account"},
                 failed
               )
    end

    html = render_component(&EmisarWeb.PoliciesLive.render/1, failed.assigns)
    assert html =~ "Couldn&#39;t load the default policy"
    refute html =~ "Save default policy"
    refute html =~ "Add ruleset"
  end

  test "a failed preview keeps the draft and offers retry without claiming an empty catalog", %{
    conn: conn,
    account: account
  } do
    runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
    Fixtures.Catalog.create_action(runner: runner, action_id: "db.read", pack_id: "test")
    {:ok, lv, _} = live(conn, ~p"/app/#{account}/policies")
    settle(lv)
    render_click(lv, "add_override", %{"editor" => "account"})
    pattern = String.duplicate("x", 201)

    render_hook(lv, "form_change", %{
      "editor" => "account",
      "policy" => %{"overrides" => %{"0" => %{"action" => pattern, "decision" => "deny"}}}
    })

    html = settle(lv)
    assert html =~ "Couldn&#39;t update the preview"
    assert html =~ "Retry preview"
    refute html =~ "No actions advertised"
    assert hd(assigns(lv).account.overrides)["action"] == pattern

    render_hook(lv, "form_change", %{
      "editor" => "account",
      "policy" => %{"overrides" => %{"0" => %{"action" => "db.*", "decision" => "deny"}}}
    })

    render_click(lv, "retry_preview", %{"editor" => "account"})
    settle(lv)
    assert {:ok, %{total: 1}} = assigns(lv).account.preview
  end

  test "a revoked target is not published after a held query completes", %{
    conn: conn,
    account: account,
    user: user
  } do
    runner =
      Fixtures.Runners.create_runner(account_id: account.id, group: "db", connected?: false)

    policy =
      Fixtures.Policies.create_policy(
        account_id: account.id,
        created_by_id: user.id,
        scope_type: :runner,
        scope_value: runner.id
      )

    member = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
    {:ok, access} = Emisar.Accounts.RunnerAccess.restricted(["db"], [])
    Fixtures.Memberships.force_runner_access(member, access)
    member_subject = Fixtures.Subjects.membership_subject(member)
    conn = log_in_user(conn, member_subject.actor)
    {:ok, lv, _} = live(conn, ~p"/app/#{account}/policies")
    settle(lv)
    hold_next_preview(account.id)
    render_click(lv, "open_ruleset", %{"uid" => policy.id})
    assert_receive {:held_preview, task}, 2_000
    Fixtures.Runners.move_to_group(runner, "hidden")
    send(task, :continue_preview)
    settle(lv)
    assert {:error, :unauthorized} = editor(lv, policy.id).preview

    refute lv |> element("#policy-rail-#{policy.id}") |> render() =~
             "No actions advertised on this target"
  end

  test "a removed selected runner remains identifiable without losing the draft target", %{
    conn: conn,
    account: account
  } do
    runner =
      Fixtures.Runners.create_runner(account_id: account.id, name: "gone", connected?: false)

    {:ok, lv, _} = live(conn, ~p"/app/#{account}/policies")
    render_click(lv, "add_ruleset", %{})
    uid = List.last(assigns(lv).rulesets).uid
    render_hook(lv, "set_target", %{"uid" => uid, "target" => "runner:#{runner.id}"})
    Fixtures.Runners.mark_deleted(runner)
    html = render_hook(lv, "search_targets", %{"uid" => uid, "search" => "missing"})
    assert html =~ "#{runner.id} — unavailable"
    assert editor(lv, uid).scope_value == runner.id

    assert has_element?(
             lv,
             "#policy-target-#{uid} option[value='runner:#{runner.id}'][selected][disabled]"
           )

    settle(lv)
  end

  def hold_preview(_event, _measurements, metadata, %{
        account_id: account_id,
        owner: owner,
        once: once
      }) do
    if String.contains?(metadata.query, "ARRAY['low'") and account_id in metadata.params and
         :atomics.compare_exchange(once, 1, 0, 1) == :ok do
      send(owner, {:held_preview, self()})

      receive do
        :continue_preview -> :ok
      after
        5_000 -> :ok
      end
    end
  end

  defp hold_next_preview(account_id) do
    id = {__MODULE__, self(), make_ref()}

    :telemetry.attach(id, [:emisar, :repo, :query], &__MODULE__.hold_preview/4, %{
      account_id: Ecto.UUID.dump!(account_id),
      owner: self(),
      once: :atomics.new(1, [])
    })

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp flush_timer(lv, uid) do
    editor = editor(lv, uid)

    if editor.preview_timer do
      Process.cancel_timer(editor.preview_timer)
      send(lv.pid, {:preview_due, uid, editor.preview_generation})
    end

    render(lv)
  end

  defp settle(lv) do
    for editor <- [assigns(lv).account | assigns(lv).rulesets], do: flush_timer(lv, editor.uid)
    render_async(lv, 2_000)
    if assigns(lv).preview_active, do: render_async(lv, 2_000)
    render(lv)
  end

  defp assigns(lv), do: :sys.get_state(lv.pid).socket.assigns
  defp editor(lv, "account"), do: assigns(lv).account
  defp editor(lv, uid), do: Enum.find(assigns(lv).rulesets, &(&1.uid == uid))

  defp scoped(account, user, group) do
    Fixtures.Policies.create_policy(
      account_id: account.id,
      created_by_id: user.id,
      scope_type: :group,
      scope_value: group
    )
  end
end
