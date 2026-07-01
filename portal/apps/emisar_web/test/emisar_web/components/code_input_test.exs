defmodule EmisarWeb.Components.CodeInputTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.code_input/1` — the iPhone-style one-box-per-
  character code entry (magic-link sign-in, TOTP, email step-up). Asserts the
  contract the `CodeInput` JS hook depends on: the hook + `phx-update="ignore"`
  container, one `data-box` input per `length`, the hidden `data-code` aggregate
  under the given `name`, the label, and the alphanumeric-vs-`numeric` switch.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  defp render_code_input(attrs) do
    assigns = %{attrs: attrs}

    rendered_to_string(~H"""
    <CoreComponents.code_input {@attrs} />
    """)
  end

  defp count(html, pattern), do: length(Regex.scan(pattern, html))

  describe "code_input/1" do
    test "renders the hook container, one box per default length, and the hidden aggregate" do
      html = render_code_input(%{id: "magic-code", name: "code", label: "Sign-in code"})

      assert html =~ ~s(phx-hook="CodeInput")
      assert html =~ ~s(phx-update="ignore")
      assert html =~ "Sign-in code"
      assert count(html, ~r/data-box/) == 6
      assert html =~ ~r/<input[^>]*type="hidden"[^>]*name="code"[^>]*data-code/s
    end

    test "the alphanumeric default filters to the code alphabet (uppercase + text inputmode)" do
      html = render_code_input(%{id: "c", name: "code", label: "Code"})

      assert html =~ ~s(data-numeric="false")
      assert html =~ ~s(inputmode="text")
      assert html =~ "uppercase"
    end

    test "numeric switches the filter + inputmode and drops the uppercase treatment" do
      html =
        render_code_input(%{id: "otp", name: "mfa[otp]", label: "6-digit code", numeric: true})

      assert html =~ ~s(data-numeric="true")
      assert html =~ ~s(inputmode="numeric")
      assert html =~ ~s(name="mfa[otp]")
      refute html =~ "uppercase"
    end

    test "length sets the box count" do
      html = render_code_input(%{id: "c", name: "code", label: "Code", length: 4})

      assert count(html, ~r/data-box/) == 4
    end

    test "only the first box advertises one-time-code autocomplete" do
      html = render_code_input(%{id: "c", name: "code", label: "Code"})

      assert count(html, ~r/autocomplete="one-time-code"/) == 1
    end
  end
end
