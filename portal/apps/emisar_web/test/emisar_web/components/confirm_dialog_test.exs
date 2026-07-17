defmodule EmisarWeb.Components.ConfirmDialogTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.confirm_dialog/1` and asserts the
  typed-confirm contract: it shows the title / body / "type <token>" prompt,
  the Confirm button is disabled until the page's `typed` value equals a
  NON-empty token, and the token/title render escaped (IL-16). The button only
  gates UI dispatch — server authz is verified in the per-page LiveView tests.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  test "carries the ConfirmDialog focus hook so the opener regains focus on close (UI-016)" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <CoreComponents.confirm_dialog
        id="del"
        title="Delete this runner"
        confirm_label="Delete runner"
        on_confirm="delete"
      >
        <:body>Removes the runner row.</:body>
      </CoreComponents.confirm_dialog>
      """)

    # The dialog shows/hides client-side, so a JS hook captures the opener and
    # restores focus to it on Escape / backdrop / Cancel (behavior verified in
    # the browser — the suite has no DOM). Without the hook focus falls to
    # <body>; this pins the wiring so that a11y regression can't return silently.
    assert html =~ ~s(phx-hook="ConfirmDialog")
    assert html =~ ~s(role="dialog")
  end

  test "renders title, body, and the type-to-confirm prompt for the token" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <CoreComponents.confirm_dialog
        id="del"
        title="Delete this runner"
        confirm_label="Delete runner"
        confirm_token="acme-db-01"
        typed=""
        on_confirm="delete"
      >
        <:body>Removes the runner row.</:body>
      </CoreComponents.confirm_dialog>
      """)

    assert html =~ "Delete this runner"
    assert html =~ "Removes the runner row."
    assert html =~ "to confirm"
    assert html =~ "acme-db-01"
    # The typed-confirm field is present, wired to the shared change handler.
    assert html =~ ~s(name="confirm_token")
    assert html =~ ~s(phx-change="confirm_typed")
  end

  test "Confirm is disabled until the typed value matches the token" do
    assigns = %{}

    # Empty typed → mismatch → Confirm disabled.
    empty =
      rendered_to_string(~H"""
      <CoreComponents.confirm_dialog
        id="del"
        title="Delete"
        confirm_label="Delete runner"
        confirm_token="acme-db-01"
        typed=""
        on_confirm="delete"
      >
        <:body>x</:body>
      </CoreComponents.confirm_dialog>
      """)

    assert confirm_button_disabled?(empty)

    # Wrong typed → still disabled.
    wrong =
      rendered_to_string(~H"""
      <CoreComponents.confirm_dialog
        id="del"
        title="Delete"
        confirm_label="Delete runner"
        confirm_token="acme-db-01"
        typed="nope"
        on_confirm="delete"
      >
        <:body>x</:body>
      </CoreComponents.confirm_dialog>
      """)

    assert confirm_button_disabled?(wrong)

    # Exact match → enabled.
    match =
      rendered_to_string(~H"""
      <CoreComponents.confirm_dialog
        id="del"
        title="Delete"
        confirm_label="Delete runner"
        confirm_token="acme-db-01"
        typed="acme-db-01"
        on_confirm="delete"
      >
        <:body>x</:body>
      </CoreComponents.confirm_dialog>
      """)

    refute confirm_button_disabled?(match)
  end

  test "a blank token can never be confirmed (page-level dialog with no target)" do
    assigns = %{}

    # Empty token AND empty typed would naively match — but a blank token must
    # keep Confirm disabled so an un-targeted page-level dialog stays inert.
    html =
      rendered_to_string(~H"""
      <CoreComponents.confirm_dialog
        id="reject-pack"
        title="Reject"
        confirm_label="Reject pack"
        confirm_token=""
        typed=""
        on_confirm="reject"
      >
        <:body>x</:body>
      </CoreComponents.confirm_dialog>
      """)

    assert confirm_button_disabled?(html)
  end

  test "no token → plain confirm: no typed field, Confirm enabled immediately" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <CoreComponents.confirm_dialog
        id="revoke"
        title="Revoke enrollment key"
        confirm_label="Revoke key"
        on_confirm="revoke"
      >
        <:body>Existing runners aren't affected.</:body>
      </CoreComponents.confirm_dialog>
      """)

    # A routine reversible action doesn't make the operator type anything.
    refute html =~ ~s(name="confirm_token")
    refute html =~ "to confirm"
    refute confirm_button_disabled?(html)
  end

  test "the token and title render escaped (IL-16 — operator/runner data)" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <CoreComponents.confirm_dialog
        id="del"
        title="<script>t</script>"
        confirm_label="Delete runner"
        confirm_token="<script>alert(1)</script>"
        typed=""
        on_confirm="delete"
      >
        <:body>x</:body>
      </CoreComponents.confirm_dialog>
      """)

    refute html =~ "<script>alert(1)</script>"
    refute html =~ "<script>t</script>"
    assert html =~ "&lt;script&gt;"
  end

  describe "confirm_button/1 — the plain-modal drop-in for data-confirm" do
    test "renders a trigger + a plain (no-typing) modal, and NEVER a native data-confirm" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.confirm_button
          id="disable-runner"
          title="Disable this runner?"
          confirm_label="Disable runner"
          on_confirm={Phoenix.LiveView.JS.push("disable")}
        >
          <:body>Stops new dispatches.</:body>
          Disable
        </CoreComponents.confirm_button>
        """)

      # The trigger OPENS the modal (no native browser dialog anywhere).
      refute html =~ "data-confirm"
      # The modal is present (its heading + Confirm label), with NO typed field.
      assert html =~ "Disable this runner?"
      assert html =~ "Disable runner"
      refute html =~ ~s(name="confirm_token")
      refute html =~ "to confirm"
    end

    test "a :neutral trigger still gets a rose (distinct-from-Cancel) modal Confirm" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.confirm_button
          id="suspend"
          title="Suspend this member?"
          confirm_label="Suspend member"
          tone={:neutral}
          on_confirm={Phoenix.LiveView.JS.push("suspend")}
        >
          <:body>They're signed out until restored.</:body>
          Suspend
        </CoreComponents.confirm_button>
        """)

      # The modal's Confirm button carries the destructive rose face so it can
      # never look identical to the neutral Cancel beside it.
      [confirm_tag] = Regex.run(~r/<button[^>]*>\s*Suspend member/, html)
      assert confirm_tag =~ "text-rose-200"
    end
  end

  # The Confirm button is the danger button labelled "Delete runner"/"Reject
  # pack"/"Revoke key" (not "Cancel"). HEEx renders a bare `disabled` attribute
  # when the button is disabled and omits it otherwise — so check whether the
  # Confirm button's opening tag carries `disabled`.
  defp confirm_button_disabled?(html) do
    # The Confirm button's opening <button ...> tag through to its label.
    [tag] = Regex.run(~r/<button[^>]*>\s*(?:Delete runner|Reject pack|Revoke key)/, html)

    # The bare boolean attribute is `disabled` followed by a space or `>` — not
    # the Tailwind `disabled:` utility classes (which contain a colon).
    Regex.match?(~r/\sdisabled[\s>]/, tag)
  end
end
