defmodule EmisarWeb.Components.CalloutTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.callout/1` — the ONE tinted callout every
  console banner/heads-up composes (design-console-ux §1), and the two thin domain
  wrappers over it (`offline_notice`, `subscription_banner`). Asserts the tone
  ramps, both variants, the navigate link form, and that the message is
  escaped (IL-16: callouts carry interpolated, attacker-influenceable text).
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  describe "callout/1" do
    test "neutral is the quiet default with an info icon" do
      assigns = %{}

      html = rendered_to_string(~H"<CoreComponents.callout>Heads up.</CoreComponents.callout>")

      assert html =~ "Heads up."
      assert html =~ "bg-zinc-900/40"
      assert html =~ "hero-information-circle-mini"
      assert html =~ "rounded-lg border"
    end

    test "amber cautions with a triangle" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H"<CoreComponents.callout tone={:amber}>Copy it now.</CoreComponents.callout>"
        )

      assert html =~ "bg-amber-500/10"
      assert html =~ "hero-exclamation-triangle-mini"
    end

    test "brand is the informational emerald" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H"<CoreComponents.callout tone={:brand}>Signed only.</CoreComponents.callout>"
        )

      assert html =~ "bg-brand-500/10"
      assert html =~ "hero-information-circle-mini"
    end

    test "rose is the danger ramp" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H"<CoreComponents.callout tone={:rose}>Run failed.</CoreComponents.callout>"
        )

      assert html =~ "bg-rose-500/10"
      assert html =~ "text-rose-200"
    end

    test "renders a bold title above the message" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H|<CoreComponents.callout tone={:rose} title="Cancelled">the why</CoreComponents.callout>|
        )

      assert html =~ "font-semibold"
      assert html =~ "Cancelled"
      assert html =~ "the why"
    end

    test "icon overrides the tone default; icon={false} renders none" do
      assigns = %{}

      overridden =
        rendered_to_string(
          ~H|<CoreComponents.callout tone={:amber} icon="hero-hand-raised">held</CoreComponents.callout>|
        )

      assert overridden =~ "hero-hand-raised"
      refute overridden =~ "hero-exclamation-triangle-mini"

      bare =
        rendered_to_string(
          ~H"<CoreComponents.callout icon={false}>quiet</CoreComponents.callout>"
        )

      refute bare =~ "hero-"
    end

    test "renders the right-aligned action slot" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.callout tone={:amber}>
          body
          <:action><button>Review</button></:action>
        </CoreComponents.callout>
        """)

      assert html =~ "Review"
      assert html =~ "shrink-0 self-center"
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
      assert html =~ "hover:bg-amber-500/[0.16]"
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
        <CoreComponents.offline_notice severity={:info} title="Runner offline">
          queues until reconnect
        </CoreComponents.offline_notice>
        """)

      assert info =~ "hero-signal-slash"
      refute info =~ "bg-zinc-900/40"
      refute info =~ "ring-1"

      critical =
        rendered_to_string(~H"""
        <CoreComponents.offline_notice severity={:critical} title="All runners offline">
          nothing can dispatch
        </CoreComponents.offline_notice>
        """)

      assert critical =~ "bg-rose-500/10"
      assert critical =~ "All runners offline"
    end
  end

  describe "subscription_banner/1" do
    test "past_due renders the rose callout; healthy statuses render nothing" do
      assigns = %{}

      past_due =
        rendered_to_string(~H|<CoreComponents.subscription_banner status="past_due" />|)

      assert past_due =~ "Payment past due"
      assert past_due =~ "bg-rose-500/10"

      healthy =
        rendered_to_string(~H|<CoreComponents.subscription_banner status="active" />|)

      refute healthy =~ "bg-rose-500/10"
      refute healthy =~ "bg-amber-500/10"
    end
  end
end
