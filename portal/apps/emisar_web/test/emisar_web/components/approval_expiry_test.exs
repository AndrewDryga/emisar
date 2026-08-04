defmodule EmisarWeb.Components.ApprovalExpiryTest do
  @moduledoc """
  `EmisarWeb.CoreComponents.approval_expiry/1` presents the lifecycle facts
  `Approvals.request_facts/2` projects; it reads no clock of its own, so every
  case here is a fixed fact map with a fixed timestamp.

  It renders that timestamp through `<.local_time>` (viewer-local,
  hover-to-absolute, live) like every other timestamp in the app. Because it's
  mid-sentence ("expires <time>"), the space before the `<time>` tag is
  load-bearing — the formatter drops the component onto its own line, so a
  `{" "}` literal guards the space HEEx would otherwise trim.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  @expires_at ~U[2026-01-01 12:00:00.000000Z]

  test "renders the expiry through <.local_time>, with a space after 'expires'" do
    assigns = %{expires_at: @expires_at}

    html =
      rendered_to_string(~H"""
      <CoreComponents.approval_expiry
        expires_at={@expires_at}
        expired?={false}
        expires_in_seconds={1800}
      />
      """)

    # Hook-driven <time>, relative mode — same model as the rest of the UI.
    assert html =~ ~s(phx-hook="LocalTime")
    assert html =~ ~s(data-format="relative")
    # The mid-sentence space is preserved: "expires <time>", never "expires<time>".
    assert html =~ ~r/expires\s<time/
    refute html =~ ~r/expires<time/
  end

  test "two hours left is still urgent — the boundary second is amber" do
    assigns = %{expires_at: @expires_at}

    html =
      rendered_to_string(~H"""
      <CoreComponents.approval_expiry
        expires_at={@expires_at}
        expired?={false}
        expires_in_seconds={7200}
      />
      """)

    assert html =~ "text-amber-400"
  end

  test "one second past the two-hour window is muted" do
    assigns = %{expires_at: @expires_at}

    html =
      rendered_to_string(~H"""
      <CoreComponents.approval_expiry
        expires_at={@expires_at}
        expired?={false}
        expires_in_seconds={7201}
      />
      """)

    assert html =~ "text-zinc-400"
    refute html =~ "text-amber-400"
  end

  test "a request at its deadline reads expired and stays muted" do
    # Exactly what Approvals projects at equality: :expired, zero left. Lapsed
    # is moot rather than urgent, so it loses the amber and the clock icon.
    assigns = %{expires_at: @expires_at}

    html =
      rendered_to_string(~H"""
      <CoreComponents.approval_expiry
        expires_at={@expires_at}
        expired?={true}
        expires_in_seconds={0}
      />
      """)

    assert html =~ "expired"
    assert html =~ "hero-no-symbol"
    assert html =~ "Expired without a decision"
    assert html =~ "text-zinc-400"
    refute html =~ "text-amber-400"
    refute html =~ "hero-clock"
  end

  test "renders nothing without an expiry" do
    # A request with no deadline is what Approvals projects as no seconds left;
    # the assign carries it because a literal nil can't type-check as :integer.
    assigns = %{expires_in_seconds: nil}

    html =
      rendered_to_string(~H"""
      <CoreComponents.approval_expiry
        expires_at={nil}
        expired?={false}
        expires_in_seconds={@expires_in_seconds}
      />
      """)

    refute html =~ "expires"
    refute html =~ "<time"
  end
end
