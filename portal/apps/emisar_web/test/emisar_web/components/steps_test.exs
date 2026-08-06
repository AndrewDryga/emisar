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

    test "plan: divide-y rows whose mark reads at the row title's size" do
      assigns = %{steps: ["restart nginx", "flush the cache"]}

      html =
        rendered_to_string(~H"""
        <CoreComponents.steps variant={:plan}>
          <:step :for={step <- @steps}>{step}</:step>
        </CoreComponents.steps>
        """)

      assert html =~ "divide-y divide-zinc-800/70"
      # The mark reads at the row title's size, in a fixed column so a `32`
      # and a `1` line up — and carries no disc around it.
      assert html =~ "h-5 w-5"
      assert html =~ "text-sm font-semibold leading-5 tabular-nums"
      refute html =~ "rounded-full"
      # No horizontal padding — the plan list sits on the canvas, not in a panel.
      assert html =~ "gap-3 py-3"
      assert html =~ "restart nginx"
      assert html =~ ~r{>\s*2\s*</span>}
    end

    test "plan: a boxed row is the panel, so it drops the rail" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.steps variant={:plan}>
          <:step>reads as a list row</:step>
          <:step boxed>opens into a form</:step>
        </CoreComponents.steps>
        """)

      assert html =~ "border border-dashed border-zinc-800"
      assert html =~ "opens into a form"
      # One marker, for the unboxed row only.
      assert length(String.split(html, "data-steps-marker")) == 2
    end

    test "plan: parallel work replaces sequence numbers with one shared icon" do
      assigns = %{steps: ["restart node a", "restart node b"]}

      html =
        rendered_to_string(~H"""
        <CoreComponents.steps variant={:plan} marker={:parallel}>
          <:step :for={step <- @steps}>{step}</:step>
        </CoreComponents.steps>
        """)

      assert html =~ ~s(data-steps-marker="parallel")
      assert html =~ "hero-arrows-right-left"
      refute html =~ ~r{>\s*1\s*</span>}
    end
  end
end
