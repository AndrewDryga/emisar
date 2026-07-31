defmodule EmisarWeb.Components.RunbookWorkflowComponentsTest do
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.RunbookWorkflowComponents

  test "plan stage keeps the stage total when the caller renders a bounded item page" do
    assigns = %{
      stage: %{
        "title" => "Inspect the fleet",
        "mode" => "parallel",
        "max_parallel" => 3
      },
      items: [
        %{
          "action" => "linux.uptime",
          "runner_ref" => "edge-fra-01~sha256",
          "target_selection" => "random_one",
          "target_group" => "edge-web",
          "step_id" => "check_uptime",
          "risk" => "low",
          "args" => %{}
        }
      ]
    }

    html =
      rendered_to_string(~H"""
      <RunbookWorkflowComponents.plan_stage
        stage={@stage}
        items={@items}
        item_count={8}
      />
      """)

    assert html =~ "parallel · up to 3 at once"
    assert html =~ "8 items"
    assert html =~ "edge-fra-01"
    assert html =~ "selected from edge-web"
    assert html =~ "check_uptime"
    assert html =~ ~s(data-steps-marker="parallel")
  end
end
