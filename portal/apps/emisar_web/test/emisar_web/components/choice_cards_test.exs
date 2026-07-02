defmodule EmisarWeb.Components.ChoiceCardsTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.choice_cards/1` — the ONE radio
  choice-card group (invite role picker, policies who-can-approve). Asserts
  the sr-only radio wiring, string-compared selection with its NEUTRAL ring +
  check (never a semantic hue on a selection affordance), the optional icon
  disc, columns, and the disabled treatment.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  defp render_pair(assigns) do
    rendered_to_string(~H"""
    <CoreComponents.choice_cards
      name="policy[approval][allow_self_approval]"
      value={@value}
      disabled={@disabled}
      columns={2}
    >
      <:card value="false" icon="hero-user-group" title="A different operator">
        No signing off on your own request.
      </:card>
      <:card value="true" icon="hero-user" title="Anyone, incl. requester">
        The requester's own approval can count.
      </:card>
    </CoreComponents.choice_cards>
    """)
  end

  describe "choice_cards/1" do
    test "renders one sr-only radio per card, named and checked by string compare" do
      html = render_pair(%{value: false, disabled: false})

      assert html =~ ~s(name="policy[approval][allow_self_approval]")
      assert html =~ ~r/<input[^>]*value="false"[^>]*checked/
      refute html =~ ~r/<input[^>]*value="true"[^>]*checked/
      assert html =~ "sr-only"
      assert html =~ "A different operator"
      assert html =~ "The requester's own approval can count."
    end

    test "selection is NEUTRAL (bright ring + check), never a semantic hue" do
      html = render_pair(%{value: true, disabled: false})

      assert html =~ "bg-white/[0.04] ring-white/25"
      assert html =~ "hero-check-circle-solid"
      # The only brand usage is the keyboard focus ring.
      refute html =~ "bg-brand-500"
      refute html =~ "ring-brand-500/40"
    end

    test "icon disc renders only when a card declares an icon" do
      html = render_pair(%{value: false, disabled: false})
      assert html =~ "hero-user-group"

      assigns = %{}

      bare =
        rendered_to_string(~H"""
        <CoreComponents.choice_cards name="invite[role]" value="operator">
          <:card value="operator" title="Operator">Runs actions.</:card>
        </CoreComponents.choice_cards>
        """)

      refute bare =~ "place-items-center"
    end

    test "columns pick the grid; disabled swaps the cursor and dims" do
      html = render_pair(%{value: false, disabled: true})

      assert html =~ "sm:grid-cols-2"
      assert html =~ "cursor-not-allowed opacity-70"
      assert html =~ ~r/<input[^>]*disabled/
    end
  end
end
