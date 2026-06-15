defmodule EmisarWeb.Components.ApprovalExpiryTest do
  @moduledoc """
  `EmisarWeb.CoreComponents.approval_expiry/1` renders its timestamp through
  `<.local_time>` (viewer-local, hover-to-absolute, live) like every other
  timestamp in the app. Because it's mid-sentence ("expires <time>"), the space
  before the `<time>` tag is load-bearing — the formatter drops the component
  onto its own line, so a `{" "}` literal guards the space HEEx would otherwise
  trim. This test proves the space survives (not "expires<time").
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias EmisarWeb.CoreComponents

  test "renders the expiry through <.local_time>, with a space after 'expires'" do
    assigns = %{expires_at: DateTime.add(DateTime.utc_now(), 1800, :second)}

    html =
      rendered_to_string(~H"""
      <CoreComponents.approval_expiry expires_at={@expires_at} />
      """)

    # Hook-driven <time>, relative mode — same model as the rest of the UI.
    assert html =~ ~s(phx-hook="LocalTime")
    assert html =~ ~s(data-format="relative")
    # The mid-sentence space is preserved: "expires <time>", never "expires<time>".
    assert html =~ ~r/expires\s<time/
    refute html =~ ~r/expires<time/
  end

  test "renders nothing without an expiry" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <CoreComponents.approval_expiry expires_at={nil} />
      """)

    refute html =~ "expires"
    refute html =~ "<time"
  end
end
