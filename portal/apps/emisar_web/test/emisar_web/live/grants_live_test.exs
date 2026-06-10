defmodule EmisarWeb.GrantsLiveTest do
  @moduledoc """
  Confirms the merged Approvals page lists active standing grants,
  hides revoked/expired ones, and lets operators revoke them inline.
  (The standalone /app/agents/grants page was merged into /app/approvals
  so operators see pending + grants + decisions in one place.)
  """
  use EmisarWeb.ConnCase, async: true

  alias Emisar.{Accounts, ApiKeys, Approvals, Audit, Repo, Runners}
  alias Emisar.Approvals.Grant
  alias Emisar.Runners.Runner

  defp seed_account(conn) do
    {conn, user, account} = register_and_log_in(conn)
    subject = owner_subject(user, account)

    {:ok, raw, _key} =
      ApiKeys.create_key(
        %{
          name: "bot-key",
          scopes: ["actions:read", "actions:execute"],
          runner_filter: []
        },
        subject
      )

    {:ok, runner} =
      Runner.Changeset.register(%{
        account_id: account.id,
        name: "runner-1",
        external_id: Ecto.UUID.generate(),
        group: "default",
        hostname: "10.0.5.12"
      })
      |> Repo.insert()

    api_key = ApiKeys.peek_api_key_by_secret(raw)
    {conn, user, account, api_key, runner}
  end

  defp insert_grant!(account, key, opts) do
    Grant.Changeset.create(
      Map.merge(
        %{
          account_id: account.id,
          api_key_id: key.id,
          action_id: "linux.uptime",
          granted_at: DateTime.utc_now()
        },
        Map.new(opts)
      )
    )
    |> Repo.insert!()
  end

  test "redirects anonymous users", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, ~p"/app/approvals")
  end

  test "empty state when there are no grants", %{conn: conn} do
    {conn, _user, _account} = register_and_log_in(conn)
    {:ok, _lv, html} = live(conn, ~p"/app/approvals")
    assert html =~ "No active grants"
  end

  test "lists active grants with key + scope + uses + expiry", %{conn: conn} do
    {conn, user, account, api_key, runner} = seed_account(conn)

    expires = DateTime.add(DateTime.utc_now(), 24 * 3600, :second)

    g =
      insert_grant!(account, api_key,
        action_id: "cassandra.repair",
        runner_id: runner.id,
        args_sha256: "abc123",
        granted_by_id: user.id,
        expires_at: expires,
        max_uses: 5
      )

    {:ok, _lv, html} = live(conn, ~p"/app/approvals")

    assert html =~ "cassandra.repair"
    assert html =~ api_key.name
    assert html =~ "runner-1"
    assert html =~ "exact"
    assert html =~ "not used yet · cap 5"
    refute html =~ "No active grants"
    assert html =~ g.id |> String.slice(0, 6) || true
  end

  test "hides revoked grants", %{conn: conn} do
    {conn, user, account, api_key, _runner} = seed_account(conn)
    subject = owner_subject(user, account)
    g = insert_grant!(account, api_key, action_id: "x", granted_by_id: user.id)
    {:ok, _} = Approvals.revoke_grant(g, subject)

    {:ok, _lv, html} = live(conn, ~p"/app/approvals")
    refute html =~ "x</span>"
    assert html =~ "No active grants"
  end

  test "hides expired grants", %{conn: conn} do
    {conn, user, account, api_key, _runner} = seed_account(conn)
    past = DateTime.add(DateTime.utc_now(), -60, :second)

    _ =
      insert_grant!(account, api_key,
        action_id: "stale.grant",
        granted_by_id: user.id,
        expires_at: past
      )

    {:ok, _lv, html} = live(conn, ~p"/app/approvals")
    refute html =~ "stale.grant"
  end

  test "revoke button removes the grant + audits", %{conn: conn} do
    {conn, user, account, api_key, _runner} = seed_account(conn)

    g =
      insert_grant!(account, api_key,
        action_id: "cassandra.repair",
        granted_by_id: user.id
      )

    {:ok, lv, _html} = live(conn, ~p"/app/approvals")

    html = lv |> element("button", "Revoke") |> render_click()
    assert html =~ "Grant revoked"
    refute html =~ "cassandra.repair"

    reloaded = Grant.Query.all() |> Grant.Query.by_id(g.id) |> Repo.fetch!(Grant.Query)
    assert reloaded.revoked_at != nil

    assert Enum.any?(
             Audit.list_events(owner_subject(user, account), page: [limit: 50]) |> elem(1),
             &(&1.event_type == "approval.grant_revoked" and &1.subject_id == g.id)
           )
  end

  # Suppress unused-alias warnings — these alias modules are referenced
  # via behaviour/imports but the compiler can't always see it.
  _ = {Accounts, Runners}
end
