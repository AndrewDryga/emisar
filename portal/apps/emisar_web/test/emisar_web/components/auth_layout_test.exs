defmodule EmisarWeb.Components.AuthLayoutTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.auth_layout/1` — the split-screen shell every
  passwordless sign-in page wears. Asserts the title, the inner-block slot, the
  left-panel value prop, and the compliance footer (legal links + the legal-name
  copyright) that must not silently drop off a sign-in page.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  defp render_auth_layout(title, inner) do
    assigns = %{title: title, inner: inner}

    rendered_to_string(~H"""
    <CoreComponents.auth_layout title={@title}>{@inner}</CoreComponents.auth_layout>
    """)
  end

  describe "auth_layout/1" do
    test "renders the title, the inner block, and the value prop" do
      html = render_auth_layout("Sign in via email", "<the form slot>")

      assert html =~ "Sign in via email"
      assert html =~ "&lt;the form slot&gt;"

      # Bounded autonomy leads; approvals are a conditional policy outcome, and
      # the product term is runbooks (UI-018 — content-position-bounded-autonomy).
      assert html =~ "inside bounds you set"
      assert html =~ "allowed, denied, or held for approval"
      refute html =~ "playbook"
    end

    test "carries the compliance footer — legal links + the legal-name copyright" do
      html = render_auth_layout("Sign in", "x")

      assert html =~ ~s(href="/trust")
      assert html =~ ~s(href="/privacy")
      assert html =~ ~s(href="/terms")
      assert html =~ ~s(href="/security")
      assert html =~ "Andrii Dryga. All rights reserved."
    end
  end
end
