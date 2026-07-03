defmodule EmisarWeb.Components.CopyableIdTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.copyable_id/1` — the ONE inline copy
  affordance for machine identifiers. Asserts the value renders mono, the copy
  button carries the literal value (CSP-safe `data-copy-text`, not a selector),
  the id never free-space-truncates, and interpolated values are escaped
  (IL-16: hostnames/ids carry attacker-influenceable text).
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  describe "copyable_id/1" do
    test "renders the value mono with a copy button carrying the literal value" do
      assigns = %{}

      html = rendered_to_string(~H|<CoreComponents.copyable_id value="api-iad-3" />|)

      assert html =~ "api-iad-3"
      assert html =~ "font-mono"
      assert html =~ ~s(data-copy-text="api-iad-3")
      assert html =~ ~s(aria-label="Copy")
    end

    test "the value wraps, never free-space-truncates" do
      assigns = %{}

      html = rendered_to_string(~H|<CoreComponents.copyable_id value="10.0.5.12" />|)

      # break-words + dotted_mono <wbr>s: wraps after a dot/dash segment, never
      # sheared mid-token the way break-all did — and never truncated.
      assert html =~ "break-words"
      assert html =~ "<wbr"
      refute html =~ "truncate"
    end

    test "escapes an interpolated value — ids carry attacker-influenceable text (IL-16)" do
      assigns = %{evil: "<script>alert(1)</script>"}

      html = rendered_to_string(~H|<CoreComponents.copyable_id value={@evil} />|)

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
    end
  end
end
