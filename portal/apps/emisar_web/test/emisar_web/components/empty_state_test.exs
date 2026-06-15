defmodule EmisarWeb.Components.EmptyStateTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.empty_state/1` — asserts `tone` maps the icon
  + title to zinc (default) or danger (rose), so a load-error state reads as an
  error, not a calm empty queue. `variant` controls size/chrome, not colour.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias EmisarWeb.CoreComponents

  defp render_empty_state(attrs) do
    assigns = %{attrs: Map.merge(%{icon: "hero-check-badge", title: "Nothing here"}, attrs)}

    rendered_to_string(~H"""
    <CoreComponents.empty_state {@attrs}>Body</CoreComponents.empty_state>
    """)
  end

  describe "empty_state/1 tone" do
    test "defaults to zinc — the icon + title are zinc, never rose" do
      html = render_empty_state(%{})

      assert html =~ "text-zinc-700"
      refute html =~ "text-rose"
    end

    test "tone={:danger} maps the icon + title to rose (a real error, not an empty queue)" do
      html = render_empty_state(%{tone: :danger})

      assert html =~ "text-rose-400/70"
      assert html =~ "text-rose-200"
    end

    test "tone is independent of variant — danger is rose in the bare variant too" do
      html = render_empty_state(%{tone: :danger, variant: :bare})

      assert html =~ "text-rose-400/70"
      assert html =~ "text-rose-200"
    end
  end
end
