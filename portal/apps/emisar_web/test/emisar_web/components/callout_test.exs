defmodule EmisarWeb.Components.CalloutTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.callout/1` — the ONE icon-capped attention
  spine every console alert composes (design-console-ux §1), and the two thin
  domain wrappers over it (`offline_notice`, `subscription_banner`). Asserts the
  tone ramps, the shell-strip exception, the navigate link form, and that the message is
  escaped (IL-16: callouts carry interpolated, attacker-influenceable text).
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents
  alias EmisarWeb.DomainComponents

  describe "callout/1" do
    test "neutral is the quiet default with an info icon and spine" do
      assigns = %{}

      html = rendered_to_string(~H"<CoreComponents.callout>Heads up.</CoreComponents.callout>")

      assert html =~ "Heads up."
      assert html =~ "bg-zinc-700"
      assert html =~ "state.info"
      refute html =~ "rounded-lg border"
    end

    test "amber cautions with a triangle" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H"<CoreComponents.callout tone={:amber}>Copy it now.</CoreComponents.callout>"
        )

      assert html =~ "bg-amber-300/40"
      assert html =~ "text-amber-300"
      assert html =~ "state.warning"
    end

    test "brand is the informational emerald" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H"<CoreComponents.callout tone={:brand}>Signed only.</CoreComponents.callout>"
        )

      assert html =~ "bg-brand-400/40"
      assert html =~ "state.info"
    end

    test "rose is the danger ramp" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H"<CoreComponents.callout tone={:rose}>Run failed.</CoreComponents.callout>"
        )

      assert html =~ "bg-rose-400/40"
      assert html =~ "text-rose-400"
      # Rose is a failure, amber a caution: they carry different marks so the
      # tone is not the only thing telling them apart.
      assert html =~ "state.error"
      refute html =~ "state.warning"
    end

    test "renders a medium title above the message" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H|<CoreComponents.callout tone={:rose} title="Cancelled">the why</CoreComponents.callout>|
        )

      assert html =~ "font-medium"
      assert html =~ "Cancelled"
      assert html =~ "the why"
    end

    test "icon overrides the tone default" do
      assigns = %{}

      overridden =
        rendered_to_string(
          ~H|<CoreComponents.callout tone={:amber} icon="product.approval">held</CoreComponents.callout>|
        )

      assert overridden =~ "product.approval"
      refute overridden =~ "state.warning"
    end

    test "rejects an unregistered icon instead of rendering an invisible glyph" do
      assigns = %{}

      assert_raise ArgumentError, ~r/unknown icon/, fn ->
        rendered_to_string(~H|<CoreComponents.callout icon="">missing</CoreComponents.callout>|)
      end
    end

    test "renders the action inside the same spine" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.callout tone={:amber}>
          body
          <:action><button>Review</button></:action>
        </CoreComponents.callout>
        """)

      assert html =~ "Review"
      assert html =~ "mt-3"
    end

    test "navigate makes the whole callout a hoverable link" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.callout tone={:amber} title="2 packs need review" navigate="/app/x/packs">
          Dispatch is blocked.
          <:action>Review pack trust →</:action>
        </CoreComponents.callout>
        """)

      assert html =~ ~s(<a href="/app/x/packs")
      assert html =~ "hover:bg-white/[0.04]"
      assert html =~ "Review pack trust →"
    end

    test "the strip variant is a flush full-width row, not a rounded box" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H"<CoreComponents.callout tone={:brand} variant={:strip}>nudge</CoreComponents.callout>"
        )

      assert html =~ "border-b"
      refute html =~ "rounded-lg"
    end

    test "appends extra class for positioning" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H|<CoreComponents.callout class="mt-4">positioned</CoreComponents.callout>|
        )

      assert html =~ "mt-4"
    end

    test "the message is HTML-escaped — it can carry attacker-influenced text (IL-16)" do
      assigns = %{evil: "<script>alert(1)</script>"}

      html = rendered_to_string(~H"<CoreComponents.callout>{@evil}</CoreComponents.callout>")

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
    end
  end

  describe "offline_notice/1" do
    test "maps severity to the tone ramp with the signal-slash icon" do
      assigns = %{}

      # `:info` is a posture fact — the NAKED note grammar, no box wash.
      info =
        rendered_to_string(~H"""
        <DomainComponents.offline_notice severity={:info} title="Runner offline">
          queues until reconnect
        </DomainComponents.offline_notice>
        """)

      assert info =~ "state.offline"
      refute info =~ "bg-zinc-900/40"
      refute info =~ "ring-1"

      critical =
        rendered_to_string(~H"""
        <DomainComponents.offline_notice severity={:critical} title="All runners offline">
          nothing can dispatch
        </DomainComponents.offline_notice>
        """)

      assert critical =~ "bg-rose-400/40"
      assert critical =~ "All runners offline"
    end
  end

  describe "subscription_banner/1" do
    test "dunning renders the rose callout; healthy states render nothing" do
      assigns = %{}

      dunning =
        rendered_to_string(
          ~H|<DomainComponents.subscription_banner entitlement_state={:dunning} status="past_due" />|
        )

      assert dunning =~ "Payment recovery in progress"
      assert dunning =~ "Paid features remain available"
      assert dunning =~ "bg-rose-400/40"

      healthy =
        rendered_to_string(
          ~H|<DomainComponents.subscription_banner entitlement_state={:active} status="active" />|
        )

      refute healthy =~ "bg-rose-400/40"
      refute healthy =~ "bg-amber-300/40"
    end

    test "expired and unresolved states explain the access boundary" do
      assigns = %{}

      expired =
        rendered_to_string(
          ~H|<DomainComponents.subscription_banner entitlement_state={:expired} status="canceled" />|
        )

      assert expired =~ "Subscription ended"
      assert expired =~ "Free limits"
      assert expired =~ "Paid integrations are dormant"

      unresolved =
        rendered_to_string(
          ~H|<DomainComponents.subscription_banner entitlement_state={:unresolved} status="mystery" />|
        )

      assert unresolved =~ "Billing status unavailable"
      assert unresolved =~ "an unused one-time audit CSV allowance"
    end
  end
end
