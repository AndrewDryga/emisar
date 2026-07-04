defmodule EmisarWeb.AuditDownloadControllerTest do
  @moduledoc """
  The audit CSV download: session-authed, filter-aware, Team+ plan-gated, and
  self-logging (`audit.exported`) like the SIEM feed.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Audit, Fixtures, Repo}

  describe "GET /app/:account/audit/download" do
    test "streams the filtered trail as CSV and self-logs the export", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      Fixtures.Accounts.create_subscription(account, "team")

      {:ok, _} =
        Audit.log(account.id, "user.invited",
          actor_kind: "user",
          actor_id: Ecto.UUID.generate(),
          actor_label: "alice@example.com"
        )

      {:ok, _} =
        Audit.log(account.id, "policy.updated",
          actor_kind: "user",
          actor_id: Ecto.UUID.generate(),
          actor_label: "bob@example.com"
        )

      conn = get(conn, ~p"/app/#{account}/audit/download?event_type=user.invited")

      assert response_content_type(conn, :csv)

      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ ~s(attachment; filename="audit-#{account.slug}-)

      body = response(conn, 200)
      assert body =~ "occurred_at_utc,event_type,severity"
      # The Type filter applied — alice's event exports, bob's doesn't.
      assert body =~ "alice@example.com"
      refute body =~ "bob@example.com"

      # Watch the watchers: the download itself lands in the trail.
      exported =
        Repo.all(Audit.Event) |> Enum.filter(&(&1.event_type == "audit.exported"))

      assert length(exported) == 1
    end

    test "a free-plan account is redirected to billing, exporting nothing", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, _} = Audit.log(account.id, "user.invited", actor_kind: "user", actor_label: "x")

      conn = get(conn, ~p"/app/#{account}/audit/download")

      assert redirected_to(conn) == ~p"/app/#{account}/settings/billing"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Audit export is available on the Team plan."

      assert Repo.all(Audit.Event) |> Enum.filter(&(&1.event_type == "audit.exported")) == []
    end

    test "another account's slug 404s before any data is read", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      other_account = Fixtures.Accounts.create_account(plan: "team")

      # The slug gate treats a non-membership like an unknown account — a hard
      # 404 before the controller (or any data read) runs.
      assert_error_sent 404, fn ->
        get(conn, ~p"/app/#{other_account}/audit/download")
      end
    end
  end
end
