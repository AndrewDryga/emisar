defmodule EmisarWeb.RunbookEditorPublishPanelTest do
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Catalog, Fixtures, Runbooks}
  alias EmisarWeb.RunbookDraft

  setup %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    %{conn: conn, user: user, account: account}
  end

  test "a clean live runbook gets a run check, not a publish pitch", %{
    conn: conn,
    user: user,
    account: account
  } do
    arrange_current_action(account, user)

    published =
      [
        account_id: account.id,
        created_by_id: user.id,
        title: "Fleet health",
        slug: "fleet-health",
        definition: canonical_definition(valid_draft())
      ]
      |> Fixtures.Runbooks.create_runbook()
      |> Fixtures.Runbooks.publish_runbook()

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{published.id}/edit")
    send(lv.pid, {:runbook_preview, 1})
    html = render(lv)

    assert html =~ "Run check"
    assert html =~ "Validated"
    assert html =~ "This definition resolves and can be executed"
    refute html =~ "Publish check"
    refute html =~ "Ready to publish"

    # Editing diverges from live, so the publish story returns.
    change(lv, valid_draft(title: "Fleet health edited"))
    send(lv.pid, {:runbook_preview, 2})
    html = render(lv)

    assert html =~ "Publish check"
    assert html =~ "Ready to publish"
    refute html =~ "Run check"
  end

  test "a clean live runbook that stops resolving reports blocked executions", %{
    conn: conn,
    user: user,
    account: account
  } do
    runner = arrange_current_action(account, user)

    published =
      [
        account_id: account.id,
        created_by_id: user.id,
        title: "Fleet health",
        slug: "fleet-health",
        definition: canonical_definition(valid_draft())
      ]
      |> Fixtures.Runbooks.create_runbook()
      |> Fixtures.Runbooks.publish_runbook()

    Fixtures.Catalog.delete_actions_for_runner(runner.id)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{published.id}/edit")
    send(lv.pid, {:runbook_preview, 1})
    html = render(lv)

    assert html =~ "Run check"
    assert html =~ "Current infrastructure blocks new executions"
    refute html =~ "blocks publication"
  end

  defp valid_draft(attrs \\ %{}) do
    attrs = Map.new(attrs)

    RunbookDraft.new()
    |> Map.merge(%{
      "title" => attrs[:title] || "Fleet health",
      "slug" => "fleet-health",
      "description" => "Inspect the current fleet.",
      "context_markdown" => "## Before you run\n\nConfirm the incident scope.",
      "inputs" => [],
      "stages" => [
        %{
          "id" => "inspect",
          "title" => "Inspect",
          "mode" => "parallel",
          "max_parallel" => "4",
          "steps" => [
            %{
              "id" => "uptime",
              "pack_id" => "linux-core",
              "action" => "linux.uptime",
              "target_selection" => "all",
              "target_refs" => ["group:default"],
              "args" => [],
              "outputs" => [],
              "success" => [],
              "wait" => %{
                "enabled" => "false",
                "interval_seconds" => "10",
                "timeout_seconds" => "120",
                "max_attempts" => "12"
              }
            }
          ]
        }
      ]
    })
  end

  defp canonical_definition(draft),
    do: draft |> RunbookDraft.command() |> Runbooks.Authoring.build_v1()

  defp change(lv, draft) do
    render_change(lv, "draft_changed", %{
      "_target" => ["draft", "title"],
      "draft" => form_params(draft)
    })
  end

  defp form_params(draft) do
    draft
    |> Map.update!("inputs", &indexed/1)
    |> Map.update!("stages", fn stages ->
      stages
      |> Enum.map(fn stage ->
        Map.update!(stage, "steps", fn steps ->
          steps
          |> Enum.map(fn step ->
            step
            |> Map.update!("args", &indexed/1)
            |> Map.update!("outputs", &indexed/1)
            |> Map.update!("success", &indexed/1)
          end)
          |> indexed()
        end)
      end)
      |> indexed()
    end)
  end

  defp indexed(values),
    do: values |> Enum.with_index() |> Map.new(fn {value, index} -> {to_string(index), value} end)

  defp arrange_current_action(account, user) do
    runner = Fixtures.Runners.create_runner(account_id: account.id)
    hash = Fixtures.Catalog.pack_hash("linux-core-1.4.3")

    assert {:ok, runner} =
             Catalog.observe_state(runner, %{
               "hostname" => runner.hostname,
               "version" => runner.runner_version,
               "labels" => runner.labels,
               "enforce_signatures" => false,
               "packs" => %{"linux-core" => %{"version" => "1.4.3", "hash" => hash}},
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
                   "args" => [],
                   "examples" => [],
                   "search_terms" => []
                 }
               ]
             })

    subject = owner_subject(user, account)
    versions = Fixtures.Catalog.list_pack_versions(subject.account.id)

    Enum.each(versions, fn version ->
      if version.trust_state != :trusted do
        assert {:ok, _version} = Catalog.trust_pack_version(version.id, subject)
      end
    end)

    Fixtures.Policies.create_policy(account_id: account.id)
    runner
  end
end
