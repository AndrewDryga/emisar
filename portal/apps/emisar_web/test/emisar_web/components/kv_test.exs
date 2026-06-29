defmodule EmisarWeb.Components.KvTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.kv/1` in both layouts. `:row` (default) is
  the label-left / value-right flex row detail panes use; `:grid` emits a bare
  `<dt>`/`<dd>` mono pair (no wrapper) so a caller's grid `<dl>` aligns columns —
  the shape the Packs pending-trust readout uses. Label and value are escaped
  (IL-16): both surfaces ingest hash/text that is ultimately runner-influenced.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  defp render_kv(attrs, body) do
    assigns = %{attrs: attrs, body: body}

    rendered_to_string(~H"""
    <CoreComponents.kv {@attrs}>{@body}</CoreComponents.kv>
    """)
  end

  describe "row layout (default)" do
    test "wraps label + value in a justified flex row" do
      html = render_kv(%{label: "Hostname"}, "acme-db-01")

      assert html =~ "flex items-baseline justify-between"
      assert html =~ ~r{<dt[^>]*>Hostname</dt>}
      assert html =~ ~r{<dd[^>]*>acme-db-01</dd>}
      # The value is right-aligned and not mono in the row layout.
      assert html =~ "text-right"
      refute html =~ "font-mono"
    end
  end

  describe "grid layout" do
    test "emits a bare mono dt/dd pair with no wrapping div" do
      html = render_kv(%{label: "trusted:", layout: :grid}, "abc123")

      assert html =~ ~r{<dt class="font-mono[^"]*">trusted:</dt>}
      assert html =~ ~r{<dd class="break-all font-mono[^"]*">abc123</dd>}
      # No flex-row wrapper — the dt/dd are direct grid children of the dl.
      refute html =~ "justify-between"
    end
  end

  test "escapes the label and the value (no stored XSS — IL-16)" do
    for layout <- [:row, :grid] do
      html = render_kv(%{label: "<b>k</b>", layout: layout}, "<script>x</script>")

      refute html =~ "<b>k</b>"
      refute html =~ "<script>x</script>"
      assert html =~ "&lt;b&gt;k&lt;/b&gt;"
      assert html =~ "&lt;script&gt;x&lt;/script&gt;"
    end
  end
end
