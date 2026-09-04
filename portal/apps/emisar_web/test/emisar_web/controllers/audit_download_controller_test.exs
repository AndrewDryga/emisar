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

      params = %{event_type: "user.invited", from: "2020-01-01T00:00"}
      conn = get(conn, ~p"/app/#{account}/audit/download?#{params}")

      assert response_content_type(conn, :csv)

      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ ~s(attachment; filename="audit-#{account.slug}-)

      body = response(conn, 200)
      assert body =~ "id,occurred_at_utc,event_type,severity"
      # The Type filter applied — alice's event exports, bob's doesn't.
      assert body =~ "alice@example.com"
      refute body =~ "bob@example.com"

      # `id` is the join key between this file and the NDJSON export. Without it
      # the two shared no identifier, and their timestamps differ in name,
      # format and precision — so "the auditor's CSV and the SIEM's copy of the
      # same window" could not be reconciled at all.
      [event] = Repo.all(Audit.Event) |> Enum.filter(&(&1.event_type == "user.invited"))
      assert body =~ event.id

      [exported] =
        Repo.all(Audit.Event) |> Enum.filter(&(&1.event_type == "audit.exported"))

      assert exported.payload == %{
               "count" => 1,
               "event_types" => ["user.invited"],
               "from" => "2020-01-01T00:00:00Z",
               "limit" => nil,
               "transport" => "csv"
             }
    end

    test "a free-plan account is redirected to billing, exporting nothing", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, _} = Audit.log(account.id, "user.invited", actor_kind: "user", actor_label: "x")

      conn = get(conn, ~p"/app/#{account}/audit/download")

      assert redirected_to(conn) == ~p"/app/#{account}/settings/billing"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
               "Audit export is available on the Team plan."

      assert Repo.all(Audit.Event) |> Enum.filter(&(&1.event_type == "audit.exported")) == []
    end

    test "a view over the row cap is REFUSED with guidance — never silently truncated", %{
      conn: conn
    } do
      {conn, _user, account} = register_and_log_in(conn)
      Fixtures.Accounts.create_subscription(account, "team")

      Emisar.Config.put_override(:emisar, :audit_csv_max_rows, 2)
      # Ordinary audit reads now use a planner estimate. Export preflight must
      # still count exactly before deciding the bounded CSV can be downloaded.
      Emisar.Config.put_override(:emisar, :exact_count_ceiling, -1)

      for n <- 1..3 do
        {:ok, _} =
          Audit.log(account.id, "user.invited", actor_kind: "user", actor_label: "u#{n}")
      end

      conn = get(conn, ~p"/app/#{account}/audit/download")

      assert redirected_to(conn) =~ ~p"/app/#{account}/audit"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "caps at 2"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "contact Support"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "prepare the complete export"
      # No export was logged — nothing left the building.
      assert Repo.all(Audit.Event) |> Enum.filter(&(&1.event_type == "audit.exported")) == []
    end

    test "an empty view redirects with 'nothing to export' instead of a bare header file", %{
      conn: conn
    } do
      {conn, _user, account} = register_and_log_in(conn)
      Fixtures.Accounts.create_subscription(account, "team")

      conn = get(conn, ~p"/app/#{account}/audit/download?event_type=runbook.published")

      assert redirected_to(conn) =~ ~p"/app/#{account}/audit"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Nothing to export"
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

    test "formula-leading audit values are exported as text, not spreadsheet formulas", %{
      conn: conn
    } do
      {conn, _user, account} = register_and_log_in(conn)
      Fixtures.Accounts.create_subscription(account, "team")

      {:ok, _} =
        Audit.log(account.id, "user.invited",
          actor_kind: "user",
          actor_label: "=HYPERLINK(\"https://attacker.test\")"
        )

      body =
        conn |> get(~p"/app/#{account}/audit/download?event_type=user.invited") |> response(200)

      assert body =~ "\"\t=HYPERLINK(\"\"https://attacker.test\"\")\""
    end

    test "strips hostile metadata from historical CSV rows", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      Fixtures.Accounts.create_subscription(account, "team")

      _event =
        %Audit.Event{
          account_id: account.id,
          occurred_at: DateTime.utc_now(),
          event_type: "user.invited",
          actor_kind: "system"
        }
        |> Ecto.Changeset.change(
          ip_address: "203.0." <> <<27>> <> "113.7",
          request_id: "req\u200D123"
        )
        |> Repo.insert!()

      body =
        conn |> get(~p"/app/#{account}/audit/download?event_type=user.invited") |> response(200)

      assert body =~ "203.0.113.7"
      assert body =~ "req123"
      refute body =~ <<27>>
      refute body =~ "\u200D"
    end
  end
end
