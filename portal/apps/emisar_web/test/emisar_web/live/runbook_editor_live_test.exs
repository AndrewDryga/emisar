defmodule EmisarWeb.RunbookEditorLiveTest do
  use EmisarWeb.ConnCase, async: true

  describe "GET /app/runbooks/new" do
    test "renders the visual step builder", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, lv, html} = live(conn, ~p"/app/runbooks/new")

      # Top-level shape: step list with add button. Each step is an
      # action dispatch — the assert step type used to exist in the UI
      # but had no backing executor and was ripped out.
      assert html =~ "Steps"
      assert html =~ "Add step"
      refute html =~ "Assert"
      refute html =~ "steps_json"

      # Adding a step inserts another card.
      before_count = count_step_cards(render(lv))
      render_click(lv, "add_action_step", %{})
      after_count = count_step_cards(render(lv))
      assert after_count == before_count + 1
    end

    test "Action field renders before Step ID — picking action auto-derives id", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, lv, html} = live(conn, ~p"/app/runbooks/new")

      # In the rendered step card, the Action <input name="action_id">
      # must come BEFORE the Step ID <input name="step_id"> so the form
      # asks "what does this step do?" before "what should we call it?".
      action_pos = :binary.match(html, "name=\"action_id\"") |> elem(0)
      step_pos = :binary.match(html, "name=\"step_id\"") |> elem(0)
      assert action_pos < step_pos, "Action field should render above Step ID"

      # Default step id is auto-generated as step<digits>. Picking an
      # action should swap that placeholder for a slug derived from the
      # action id. Custom-typed ids are preserved (covered separately).
      render_change(lv, "step_change", %{
        "index" => "0",
        "step_id" => "step123",
        "action_id" => "linux.uptime",
        "selector_kind" => "group",
        "selector_value" => "linux"
      })

      html2 = render(lv)
      assert html2 =~ "linux_uptime"
      refute html2 =~ ~s(value="step123")
    end

    test "custom step id is preserved when action changes", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/runbooks/new")

      # Operator types a custom id first.
      render_change(lv, "step_change", %{
        "index" => "0",
        "step_id" => "disk_check",
        "action_id" => "",
        "selector_kind" => "group",
        "selector_value" => ""
      })

      # Then picks an action — id should NOT be overwritten.
      render_change(lv, "step_change", %{
        "index" => "0",
        "step_id" => "disk_check",
        "action_id" => "linux.df",
        "selector_kind" => "group",
        "selector_value" => "linux"
      })

      html = render(lv)
      assert html =~ ~s(value="disk_check")
      refute html =~ ~s(value="linux_df")
    end
  end

  defp count_step_cards(html) do
    html
    |> String.split("phx-change=\"step_change\"")
    |> length()
    |> Kernel.-(1)
  end
end
