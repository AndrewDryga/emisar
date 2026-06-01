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
  end

  defp count_step_cards(html) do
    html
    |> String.split("phx-change=\"step_change\"")
    |> length()
    |> Kernel.-(1)
  end
end
