defmodule EmisarWeb.Components.StatusNoteTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.status_note/1` — the ONE naked
  icon+title+body note grammar (design-system §8.1: a note about the surface
  is status grammar, never a wash box). Asserts the tone ramps color the icon
  only, the two title tiers, and that the body is escaped (IL-16).
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  describe "status_note/1" do
    test "renders icon, title, and body with the neutral tone by default" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.status_note icon="hero-key" title="Live credential">
          Treat it like a password.
        </CoreComponents.status_note>
        """)

      assert html =~ "hero-key"
      assert html =~ "text-zinc-400"
      assert html =~ "Live credential"
      assert html =~ "Treat it like a password."
      # supporting-note tier: medium title, no box chrome
      assert html =~ "font-medium text-zinc-200"
      refute html =~ "ring-1"
      refute html =~ "rounded-lg border"
    end

    test "tone colors the icon only — amber" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.status_note icon="hero-key" tone={:amber} title="New key">
          Copy it now.
        </CoreComponents.status_note>
        """)

      assert html =~ "text-amber-300"
    end

    test "primary lifts the title to the page's strongest status voice" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.status_note
          icon="hero-shield-check"
          tone={:brand}
          title="Signed dispatch only"
          primary
        >
          The portal can't dispatch here.
        </CoreComponents.status_note>
        """)

      assert html =~ "font-semibold text-zinc-100"
      assert html =~ "text-brand-400"
    end

    test "the body is escaped (attacker-influenceable text can ride in it)" do
      assigns = %{payload: "<script>alert(1)</script>"}

      html =
        rendered_to_string(~H"""
        <CoreComponents.status_note icon="hero-key" title="Note">
          {@payload}
        </CoreComponents.status_note>
        """)

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end
  end
end
