defmodule EmisarWeb.Components.StepsTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.steps/1` — the ONE numbered-steps list
  (SSO guides, agent connect steps, install checks, the runbook plan).
  Asserts slot-order numbering and the guide/plan variants.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  describe "steps/1" do
    test "guide: bare list numerals derive from slot order — no circle chrome" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.steps class="mt-3">
          <:step>Create the app.</:step>
          <:step>Register the redirect URI.</:step>
          <:step>Paste the client id.</:step>
        </CoreComponents.steps>
        """)

      assert html =~ ~r{>\s*1\.\s*</span>}
      assert html =~ ~r{>\s*2\.\s*</span>}
      assert html =~ ~r{>\s*3\.\s*</span>}
      assert html =~ "Create the app."
      refute html =~ "rounded-full"
      assert html =~ "mt-3"
      refute html =~ "divide-y"
    end

    test "plan: divide-y rows with the larger circles" do
      assigns = %{steps: ["restart nginx", "flush the cache"]}

      html =
        rendered_to_string(~H"""
        <CoreComponents.steps variant={:plan}>
          <:step :for={step <- @steps}>{step}</:step>
        </CoreComponents.steps>
        """)

      assert html =~ "divide-y divide-zinc-900"
      assert html =~ "h-6 w-6"
      assert html =~ "px-5 py-3"
      assert html =~ "restart nginx"
      assert html =~ ~r{>\s*2\s*</span>}
    end
  end
end
