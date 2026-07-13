defmodule EmisarWeb.Components.AvatarTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.avatar/1` — the ONE initial-letter
  identity disc (design-console-ux §1). Asserts the initial derivation, the
  circle/square shapes, the size ramp, and that the letter is escaped.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  describe "avatar/1" do
    test "renders the name's first letter in the default md circle" do
      assigns = %{}

      html = rendered_to_string(~H|<CoreComponents.avatar name="Maya Chen" />|)

      assert html =~ ~r{>\s*M\s*</span>}
      assert html =~ "rounded-full"
      assert html =~ "h-10 w-10"
      assert html =~ "uppercase"
    end

    test "square xs is the workspace-switcher shape" do
      assigns = %{}

      html =
        rendered_to_string(~H|<CoreComponents.avatar name="acme" shape={:square} size={:xs} />|)

      assert html =~ ~r{>\s*a\s*</span>}
      assert html =~ "rounded-sm"
      assert html =~ "h-4 w-4"
    end

    test "a nil name degrades to the placeholder initial" do
      assigns = %{name: nil}

      html = rendered_to_string(~H|<CoreComponents.avatar name={@name} />|)

      assert html =~ ~r{>\s*\?\s*</span>}
    end

    test "the initial is HTML-escaped" do
      assigns = %{}

      html = rendered_to_string(~H|<CoreComponents.avatar name="<script>" />|)

      assert html =~ "&lt;"
      refute html =~ "<script>"
    end
  end
end
