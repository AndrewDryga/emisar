defmodule EmisarWeb.AuditDownloadControllerTest do
  @moduledoc """
  The audit CSV download: session-authed, filter-aware, one-time for a Free
  owner, repeatable when entitled, and self-logging like the SIEM feed.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Audit, Fixtures, Repo}

  describe "POST /app/:account/audit/download" do
    test "GET is explicitly read-only and points callers to POST", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      conn = get(conn, ~p"/app/#{account}/audit/download")

      assert response(conn, 405) == "Method Not Allowed"
      assert get_resp_header(conn, "allow") == ["POST"]
      refute Repo.reload!(account).one_time_audit_csv_exported_at
    end

    test "POST requires the browser CSRF token", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, _} = Audit.log(account.id, "user.invited", actor_kind: "user")
      show_conn = get(conn, ~p"/app/#{account}/audit")
      csrf_token = Plug.CSRFProtection.get_csrf_token()

      assert_error_sent(403, fn ->
        conn
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
        |> post(~p"/app/#{account}/audit/download", %{})
      end)

      allowed =
        show_conn
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
        |> post(~p"/app/#{account}/audit/download", %{"_csrf_token" => csrf_token})

      assert response(allowed, 200) =~ "user.invited"
    end

    test "exports the filtered trail as CSV and self-logs the export", %{conn: conn} do
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
      conn = post(conn, ~p"/app/#{account}/audit/download?#{params}")

      assert response_content_type(conn, :csv)

      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ ~s(attachment; filename="audit-#{account.slug}-)

      body = response(conn, 200)
      assert body =~ "occurred_at_utc,event_type,severity"
      # The Type filter applied — alice's event exports, bob's doesn't.
      assert body =~ "alice@example.com"
      refute body =~ "bob@example.com"

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

    test "a Free owner gets one CSV, then the durable claim refuses a second", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, _} = Audit.log(account.id, "user.invited", actor_kind: "user", actor_label: "x")

      first = post(conn, ~p"/app/#{account}/audit/download")

      assert response_content_type(first, :csv)
      assert response(first, 200) =~ "user.invited"
      assert Repo.reload!(account).one_time_audit_csv_exported_at

      second = post(recycle(first), ~p"/app/#{account}/audit/download")

      assert redirected_to(second) == ~p"/app/#{account}/audit"

      assert Phoenix.Flash.get(second.assigns.flash, :error) ==
               "The one-time audit CSV was already created. Upgrade to Team for repeated exports."

      assert Repo.all(Audit.Event)
             |> Enum.count(&(&1.event_type == "audit.exported")) == 1
    end

    test "an active one-time reservation asks the owner to retry instead of spending it", %{
      conn: conn
    } do
      {conn, owner, account} = register_and_log_in(conn)
      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)
      assert {:ok, access} = Audit.start_csv_export(subject)
      {:ok, _} = Audit.log(account.id, "user.invited", actor_kind: "user")

      blocked = post(conn, ~p"/app/#{account}/audit/download")

      assert redirected_to(blocked) == ~p"/app/#{account}/audit"
      assert Phoenix.Flash.get(blocked.assigns.flash, :info) =~ "already being prepared"
      refute Repo.reload!(account).one_time_audit_csv_exported_at
      assert Audit.cancel_csv_export(subject, access) == :ok
    end

    test "a Free admin cannot consume the owner's one-time CSV", %{conn: conn} do
      account = Fixtures.Accounts.create_account()
      admin = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: admin.id,
        role: "admin"
      )

      {:ok, _} = Audit.log(account.id, "user.invited", actor_kind: "user", actor_label: "x")

      denied = conn |> log_in_user(admin) |> post(~p"/app/#{account}/audit/download")

      assert redirected_to(denied) == ~p"/app/#{account}/settings/billing"

      assert Phoenix.Flash.get(denied.assigns.flash, :info) ==
               "Repeated CSV export is available on Team. Ask an account owner for the one-time CSV."

      refute Repo.reload!(account).one_time_audit_csv_exported_at
    end

    test "a view over the row cap is REFUSED with guidance — never silently truncated", %{
      conn: conn
    } do
      {conn, _user, account} = register_and_log_in(conn)
      Fixtures.Accounts.create_subscription(account, "team")

      Emisar.Config.put_override(:emisar_web, :audit_download_max_rows, 2)
      # Force ordinary AuditLive reads onto the planner-estimate path. The CSV
      # preflight must still request an exact count and refuse all three rows.
      Emisar.Config.put_override(:emisar, :exact_count_ceiling, -1)

      for n <- 1..3 do
        {:ok, _} =
          Audit.log(account.id, "user.invited", actor_kind: "user", actor_label: "u#{n}")
      end

      conn = post(conn, ~p"/app/#{account}/audit/download")

      assert redirected_to(conn) =~ ~p"/app/#{account}/audit"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "caps at 2"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "SIEM export API"
      # No export was logged — nothing left the building.
      assert Repo.all(Audit.Event) |> Enum.filter(&(&1.event_type == "audit.exported")) == []
    end

    test "an oversized Free view does not consume the one-time CSV", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      Emisar.Config.put_override(:emisar_web, :audit_download_max_rows, 2)

      for n <- 1..3 do
        {:ok, _} =
          Audit.log(account.id, "user.invited", actor_kind: "user", actor_label: "u#{n}")
      end

      {:ok, _} = Audit.log(account.id, "policy.updated", actor_kind: "user")

      oversized = post(conn, ~p"/app/#{account}/audit/download")

      assert redirected_to(oversized) =~ ~p"/app/#{account}/audit"
      assert Phoenix.Flash.get(oversized.assigns.flash, :error) =~ "did not use"
      refute Repo.reload!(account).one_time_audit_csv_exported_at

      csv =
        oversized
        |> recycle()
        |> post(~p"/app/#{account}/audit/download?event_type=policy.updated")

      assert response(csv, 200) =~ "policy.updated"
      assert Repo.reload!(account).one_time_audit_csv_exported_at
    end

    test "an empty view redirects with 'nothing to export' instead of a bare header file", %{
      conn: conn
    } do
      {conn, _user, account} = register_and_log_in(conn)
      conn = post(conn, ~p"/app/#{account}/audit/download?event_type=runbook.published")

      assert redirected_to(conn) =~ ~p"/app/#{account}/audit"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Nothing to export"
      refute Repo.reload!(account).one_time_audit_csv_exported_at
    end

    test "redirects preserve only audit filters and never expose the form CSRF token", %{
      conn: conn
    } do
      {conn, _user, account} = register_and_log_in(conn)

      redirected =
        post(conn, ~p"/app/#{account}/audit/download", %{
          "_csrf_token" => "browser-secret",
          "event_type" => "runbook.published"
        })

      location = redirected_to(redirected)
      assert location == ~p"/app/#{account}/audit?event_type=runbook.published"
      refute location =~ "browser-secret"
      refute location =~ "_csrf_token"
    end

    test "a preparation byte-cap failure sends no CSV and releases the one-time reservation", %{
      conn: conn
    } do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, _} = Audit.log(account.id, "user.invited", actor_kind: "user", actor_label: "x")
      Emisar.Config.put_override(:emisar_web, :audit_download_max_bytes, 32)

      failed = post(conn, ~p"/app/#{account}/audit/download")

      assert redirected_to(failed) == ~p"/app/#{account}/audit"
      assert Phoenix.Flash.get(failed.assigns.flash, :error) =~ "too large to prepare safely"
      assert get_resp_header(failed, "content-disposition") == []

      account = Repo.reload!(account)
      refute account.one_time_audit_csv_exported_at
      refute account.one_time_audit_csv_export_reservation_id

      Emisar.Config.put_override(:emisar_web, :audit_download_max_bytes, 1_000_000)
      retry = failed |> recycle() |> post(~p"/app/#{account}/audit/download")

      assert response(retry, 200) =~ "user.invited"
      assert Repo.reload!(account).one_time_audit_csv_exported_at
    end

    test "a paid account can repeat CSV downloads", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      Fixtures.Accounts.create_subscription(account, "team")
      {:ok, _} = Audit.log(account.id, "user.invited", actor_kind: "user")

      first = post(conn, ~p"/app/#{account}/audit/download?event_type=user.invited")
      assert response(first, 200) =~ "user.invited"

      second = post(recycle(first), ~p"/app/#{account}/audit/download?event_type=user.invited")
      assert response(second, 200) =~ "user.invited"
      refute Repo.reload!(account).one_time_audit_csv_exported_at
    end

    test "another account's slug 404s before any data is read", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      other_account = Fixtures.Accounts.create_account(plan: "team")

      # The slug gate treats a non-membership like an unknown account — a hard
      # 404 before the controller (or any data read) runs.
      assert_error_sent 404, fn ->
        post(conn, ~p"/app/#{other_account}/audit/download")
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
        conn |> post(~p"/app/#{account}/audit/download?event_type=user.invited") |> response(200)

      assert body =~ "\"\t=HYPERLINK(\"\"https://attacker.test\"\")\""
    end
  end
end
