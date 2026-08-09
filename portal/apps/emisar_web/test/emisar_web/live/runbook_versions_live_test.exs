defmodule EmisarWeb.RunbookVersionsLiveTest do
  @moduledoc """
  The runbook version history: every immutable version of one slug family,
  newest first, each linking to the editor; published versions keep their Run
  link, and unknown or cross-account slugs bounce back to the list.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Runbooks

  defp create_runbook!(user, account, title, opts \\ []) do
    subject = owner_subject(user, account)

    {:ok, runbook} =
      Runbooks.create_runbook(
        %{
          "title" => title,
          "name" => title,
          "slug" => String.downcase(String.replace(title, " ", "-")),
          "definition" => Emisar.Fixtures.Runbooks.default_definition()
        },
        subject
      )

    if opts[:published?] do
      Emisar.Fixtures.Runbooks.publish_runbook(runbook)
    else
      runbook
    end
  end

  test "lists every version newest first with editor links", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    subject = owner_subject(user, account)
    first = create_runbook!(user, account, "Deploy check", published?: true)
    {:ok, second} = Runbooks.save_new_version(first, %{"status" => "draft"}, subject)
    _other_family = create_runbook!(user, account, "Unrelated")

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runbooks/deploy-check/versions")

    assert html =~ "deploy-check"
    assert has_element?(lv, "a[href='#{~p"/app/#{account}/runbooks/#{second.id}/edit"}']")
    assert has_element?(lv, "a[href='#{~p"/app/#{account}/runbooks/#{first.id}/edit"}']")
    refute html =~ "Unrelated"

    # Newest first: the draft head's v2 row precedes the published v1 row.
    {second_pos, _length} = :binary.match(html, ~p"/app/#{account}/runbooks/#{second.id}/edit")
    {first_pos, _length} = :binary.match(html, ~p"/app/#{account}/runbooks/#{first.id}/edit")
    assert second_pos < first_pos
  end

  test "a published version keeps its Run link; a draft has none", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    subject = owner_subject(user, account)
    first = create_runbook!(user, account, "Deploy check", published?: true)
    {:ok, second} = Runbooks.save_new_version(first, %{"status" => "draft"}, subject)

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runbooks/deploy-check/versions")

    assert html =~ ~p"/app/#{account}/runbooks/#{first.id}/run"
    refute html =~ ~p"/app/#{account}/runbooks/#{second.id}/run"
  end

  test "only the newest published version is marked Live", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    subject = owner_subject(user, account)
    first = create_runbook!(user, account, "Deploy check", published?: true)
    {:ok, second} = Runbooks.save_new_version(first, %{}, subject)
    live_version = Fixtures.Runbooks.publish_runbook(second)
    {:ok, _third} = Runbooks.save_new_version(live_version, %{}, subject)

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runbooks/deploy-check/versions")

    assert html =~ "Live"
    assert has_element?(lv, "#runbook-version-#{live_version.id}-changes")

    # One row carries it: the older published v1 can still be dispatched from
    # here, but it is not what a default Run resolves to.
    assert html |> String.split("Live") |> length() == 2
  end

  test "a row opens the change against the version below it, and v1 offers none", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    subject = owner_subject(user, account)
    first = create_runbook!(user, account, "Deploy check", published?: true)

    revised =
      put_in(
        first.definition,
        ["context_markdown"],
        "Confirm the incident scope before running anything."
      )

    {:ok, second} = Runbooks.save_new_version(first, %{"definition" => revised}, subject)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/deploy-check/versions")

    refute has_element?(lv, "#runbook-version-#{first.id}-changes")
    assert has_element?(lv, "#runbook-version-#{second.id}-changes", "Changes from v1")

    refute has_element?(lv, "#runbook-version-#{second.id}-changes[open]")

    diff = render_click(lv, "toggle_diff", %{"id" => second.id})
    assert diff =~ "Confirm the incident scope before running anything."
    assert diff =~ "+ "
    assert diff =~ "- "
    assert has_element?(lv, "#runbook-version-#{second.id}-changes[open]")

    # A collapsed `details` keeps its body in the DOM, so the server-owned
    # `open` is what proves the toggle round-tripped.
    render_click(lv, "toggle_diff", %{"id" => second.id})
    refute has_element?(lv, "#runbook-version-#{second.id}-changes[open]")
  end

  test "a version whose definition did not change says so instead of an empty diff", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    subject = owner_subject(user, account)
    first = create_runbook!(user, account, "Deploy check", published?: true)
    {:ok, second} = Runbooks.save_new_version(first, %{"title" => "Deploy check v2"}, subject)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/deploy-check/versions")
    diff = render_click(lv, "toggle_diff", %{"id" => second.id})

    assert diff =~ "The definition is identical. Only the title or description changed."
  end

  test "an unknown slug bounces back to the list", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
             live(conn, ~p"/app/#{account}/runbooks/ghost/versions")

    assert to == ~p"/app/#{account}/runbooks"
    assert %{"error" => "Runbook not found."} = flash
  end

  test "another account's family reads as not found", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    other_account = Fixtures.Accounts.create_account()
    Fixtures.Runbooks.create_runbook(account_id: other_account.id, slug: "cross-account")

    assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
             live(conn, ~p"/app/#{account}/runbooks/cross-account/versions")

    assert to == ~p"/app/#{account}/runbooks"
    assert %{"error" => "Runbook not found."} = flash
  end

  test "a viewer can open the history but sees no Run link without dispatch permission", %{
    conn: conn
  } do
    {_owner_conn, user, account} = register_and_log_in(conn)
    subject = owner_subject(user, account)
    first = create_runbook!(user, account, "Deploy check", published?: true)
    {:ok, _second} = Runbooks.save_new_version(first, %{"status" => "draft"}, subject)

    viewer = Fixtures.Users.create_user()

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: viewer.id,
        role: "viewer"
      )

    {:ok, _lv, html} =
      build_conn()
      |> log_in_user(viewer)
      |> live(~p"/app/#{account}/runbooks/deploy-check/versions")

    assert html =~ "Deploy check"
    refute html =~ ~p"/app/#{account}/runbooks/#{first.id}/run"
  end
end
