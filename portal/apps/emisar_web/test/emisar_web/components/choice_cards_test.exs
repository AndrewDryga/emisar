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
      <:card value="false" icon="identity.group" title="A different operator">
        No signing off on your own request.
      </:card>
      <:card value="true" icon="identity.person" title="Anyone, incl. requester">
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

    test "the loaded selection gets the active brand ring and a neutral check" do
      html = render_pair(%{value: true, disabled: false})

      assert html =~
               ~r/<label[^>]*bg-white\/\[0\.06\][^>]*ring-2[^>]*ring-brand-500\/50[^>]*>\s*<input[^>]*value="true"[^>]*checked/

      assert html =~
               ~r/<label[^>]*bg-black\/20[^>]*ring-zinc-800[^>]*>\s*<input[^>]*value="false"/

      assert html =~ "state.selected"
      # Brand marks the active input; it never becomes a semantic fill.
      refute html =~ "bg-brand-500"
    end

    test "icon disc renders only when a card declares an icon" do
      html = render_pair(%{value: false, disabled: false})
      assert html =~ "identity.group"

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

    test "an attached selected value opens its card edge for a dependent panel" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.choice_cards
          name="access"
          value="restricted"
          attached_value="restricted"
        >
          <:card value="all" title="All runners">Every runner.</:card>
          <:card value="restricted" title="Selected runners">Named runners.</:card>
        </CoreComponents.choice_cards>
        """)

      assert html =~ ~r/<label[^>]*rounded-t-lg[^>]*>\s*<input[^>]*value="restricted"/
      assert html =~ ~r/<label[^>]*border-b-0[^>]*>\s*<input[^>]*value="restricted"/
      assert html =~ ~r/<label[^>]*rounded-lg[^>]*>\s*<input[^>]*value="all"/
      assert html =~ "peer/attached-panel"
    end
  end
end
