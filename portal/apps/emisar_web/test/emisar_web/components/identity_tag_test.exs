defmodule EmisarWeb.Components.IdentityTagTest do
  @moduledoc """
  `EmisarWeb.DomainComponents.identity_tag/1` renders a compound identity —
  `group|data-postgres` — that only reads correctly as a PAIR. These tests hold
  the halves to one unbreakable line: left to shrink, the value wrapped under
  its own label inside the pill and stranded the divider beside the empty half,
  which is what the roster's access rows shipped at their narrowest width.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.DomainComponents

  describe "identity_tag/1" do
    test "neither half breaks mid-token when the row runs out of width" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <DomainComponents.identity_tag category="group" value="data-postgres" />
        """)

      assert html =~ "group"
      assert html =~ "data-postgres"
      # The category never wraps and never gives up width — it is the shorter,
      # fixed half, so the value is what absorbs a narrow row.
      assert html =~ "shrink-0"
      assert html =~ "whitespace-nowrap"
      # `truncate` carries `white-space: nowrap`, so the value clips with an
      # ellipsis instead of wrapping under the label.
      assert html =~ "truncate"
      # Capped at its container, so a tag wider than the row clips inside the
      # row rather than pushing the whole roster sideways.
      assert html =~ "max-w-full"
    end

    test "the value stays readable through its title when the container clips it" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <DomainComponents.identity_tag category="group" value="search-opensearch" />
        """)

      assert html =~ ~s(title="search-opensearch")
    end

    test "a slot value carries no title of its own" do
      # The runner form passes the full id as the tag's own `title`; a second
      # title on the inner half would print an empty tooltip over it.
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <DomainComponents.identity_tag category="runner" title="019fe47d-918b-7aae">
          <span>api-iad-02</span>
        </DomainComponents.identity_tag>
        """)

      assert html =~ "api-iad-02"
      assert html =~ ~s(title="019fe47d-918b-7aae")
      refute html =~ ~s(title="">)
    end
  end
end
