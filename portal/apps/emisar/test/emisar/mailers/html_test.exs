defmodule Emisar.Mailers.HTMLTest do
  use ExUnit.Case, async: true
  alias Emisar.Mailers.HTML

  describe "escape/1" do
    test "escapes the characters that could break out of text or an attribute" do
      assert HTML.escape(~s(<a href="x" title='y'>Tom & Jerry</a>)) ==
               "&lt;a href=&quot;x&quot; title=&#39;y&#39;&gt;Tom &amp; Jerry&lt;/a&gt;"
    end

    test "escapes the ampersand once, not the ones it introduces" do
      assert HTML.escape("&lt;") == "&amp;lt;"
    end

    test "renders a non-binary value as its string form" do
      assert HTML.escape(42) == "42"
    end
  end
end
