defmodule EmisarWeb.Components.StatTest do
  @moduledoc """
  `EmisarWeb.CoreComponents.stat/1` — a normal value renders as-is; the
  `:unavailable` sentinel renders a muted em dash, so a tile whose underlying
  read failed reads "couldn't load" instead of a misleading 0.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  test "renders the value (bright) + label + hint" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <CoreComponents.stat label="Runners online" value="3 / 5" hint="of 5 total" />
      """)

    assert html =~ "Runners online"
    assert html =~ "3 / 5"
    assert html =~ "of 5 total"
    assert html =~ "text-zinc-50"
  end

  test "value={:unavailable} renders a muted em dash, not a misleading 0" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <CoreComponents.stat label="Team 2FA" value={:unavailable} hint="Couldn't load team data" />
      """)

    assert html =~ "—"
    # Muted, not the bright value color — so it reads as "no data", not a real value.
    # zinc-500 (not zinc-600) so the large "—" clears AA-large while staying muted.
    assert html =~ "text-zinc-500"
    refute html =~ "unavailable"
  end
end
