defmodule EmisarWeb.Components.GatedSettingTest do
  @moduledoc """
  `EmisarWeb.CoreComponents.gated_setting/1` is the one shape every account
  setting wears. The founder's report was that two of them disagreed on
  fundamentals — one buried the current value in a muted prose tail beside the
  permission note, the other showed no value at all to a member who couldn't
  change it. These tests pin the contract that settled it: the value is on the
  surface for BOTH audiences, and the permission is quiet chrome on a
  WCAG-reachable lock rather than prose competing with the description.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  describe "gated_setting/1" do
    test "a member who can change it gets the control, and no lock" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.gated_setting
          id="runner-retention"
          can_change?={true}
          value="After 1 hour inactive"
          who_can_change="Only owners and admins can change this."
        >
          <form id="runner-retention-form"><input name="hours" /></form>
        </CoreComponents.gated_setting>
        """)

      assert html =~ ~s(id="runner-retention-form")
      refute html =~ "state.locked"
      refute html =~ ~s(role="tooltip")
      # The control carries the value itself, so the chip's copy must not also
      # print — that would state the setting twice to the same reader.
      refute html =~ "After 1 hour inactive"
      refute html =~ "Only owners and admins can change this."
    end

    test "a member who can't gets the value, locked, and never the control" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.gated_setting
          id="runner-retention"
          can_change?={false}
          value="After 1 hour inactive"
          who_can_change="Only owners and admins can change this."
        >
          <form id="runner-retention-form"><input name="hours" /></form>
        </CoreComponents.gated_setting>
        """)

      assert html =~ "After 1 hour inactive"
      assert html =~ "state.locked"
      refute html =~ ~s(id="runner-retention-form")
    end

    test "the requirement is reachable on touch and keyboard, not hover alone" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.gated_setting
          id="max-grant-lifetime"
          can_change?={false}
          value="No cap"
          who_can_change="Only owners and admins can change this."
        >
          <form id="max-grant-lifetime-form"><input name="seconds" /></form>
        </CoreComponents.gated_setting>
        """)

      assert html =~ "Only owners and admins can change this."
      assert html =~ ~s(role="tooltip")
      assert html =~ ~s(tabindex="0")
      assert html =~ "group-focus-within/tooltip:opacity-100"
      # Scoped to this setting, so two locked settings on one page (Team carries
      # three) can't collide on a DOM id under the Tooltip hook.
      assert html =~ ~s(aria-describedby="max-grant-lifetime-lock")
      refute html =~ "title="
    end

    test "the locked value is content-sized and keeps the slot's box" do
      # §7.55 + the read-only-value rule: a value stretched to the control's
      # track reads as that control disabled, and the caller's spacing must
      # apply to BOTH branches or the card moves between the two states.
      assigns = %{}

      permitted =
        rendered_to_string(~H"""
        <CoreComponents.gated_setting
          id="monthly-report"
          can_change?={true}
          value="On"
          who_can_change="Only owners and admins can change this."
          class="mt-4"
        >
          <button id="monthly-report-switch">Turn off</button>
        </CoreComponents.gated_setting>
        """)

      locked =
        rendered_to_string(~H"""
        <CoreComponents.gated_setting
          id="monthly-report"
          can_change?={false}
          value="On"
          who_can_change="Only owners and admins can change this."
          class="mt-4"
        >
          <button id="monthly-report-switch">Turn off</button>
        </CoreComponents.gated_setting>
        """)

      assert permitted =~ "mt-4"
      assert locked =~ "mt-4"
      refute locked =~ "w-full"
      refute locked =~ "flex-1"
    end
  end
end
