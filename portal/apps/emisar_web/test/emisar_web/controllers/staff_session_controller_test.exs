defmodule EmisarWeb.StaffSessionControllerTest do
  @moduledoc """
  The staff sign-in at `/admin/sign_in`, driven the way a browser drives it: the
  staff cookie carries the pending sign-in between requests (`recycle/1`), and
  the emailed code is read back out of the delivered message.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Admin

  setup do
    %{staff: Fixtures.Admin.create_staff()}
  end

  defp request_code(conn, email) do
    conn = post(conn, ~p"/admin/sign_in", %{"staff" => %{"email" => email}})
    assert redirected_to(conn) == ~p"/admin/sign_in/code"
    recycle(conn)
  end

  defp emailed_code do
    assert_received {:email, sent}
    Fixtures.Auth.code_from_email(sent)
  end

  defp submit_codes(conn, code, otp),
    do: post(conn, ~p"/admin/sign_in/code", %{"sign_in" => %{"secret" => code, "otp" => otp}})

  describe "GET /admin/sign_in" do
    test "asks for the staff address, with no console doors before sign-in", %{conn: conn} do
      html = conn |> get(~p"/admin/sign_in") |> html_response(200)

      assert html =~ "Staff sign-in"
      assert html =~ ~s(name="staff[email]")
      refute html =~ "Sign out"
      refute html =~ "LiveDashboard"
    end

    test "a signed-in staff browser goes to the console", %{conn: conn} do
      {conn, _staff_session} = log_in_staff(conn)

      assert redirected_to(get(conn, ~p"/admin/sign_in")) == ~p"/admin"
    end
  end

  describe "the two-step sign-in" do
    test "the emailed code and the authenticator code start a staff session", %{
      conn: conn,
      staff: staff
    } do
      conn = request_code(conn, staff.email)
      code = emailed_code()
      assert conn |> get(~p"/admin/sign_in/code") |> html_response(200) =~ staff.email

      conn = submit_codes(conn, code, Fixtures.Admin.totp_code(staff))

      assert redirected_to(conn) == ~p"/admin"
      raw = get_session(conn, :staff_token)
      assert {:ok, staff_session} = Admin.fetch_staff_session(raw)
      assert staff_session.staff_id == staff.id
      assert get_session(conn, :live_socket_id) == Admin.staff_session_socket_topic(raw)
      assert get_session(conn, :staff_sign_in) == nil

      assert {:ok, _live, html} = conn |> recycle() |> live(~p"/admin")
      assert html =~ staff.email
      assert html =~ ~s(href="/admin/sign_out")
    end

    test "an address with no staff login lands on the same page and gets nothing", %{
      conn: conn
    } do
      conn = request_code(conn, "nobody@emisar.test")

      refute_received {:email, _sent}
      assert conn |> get(~p"/admin/sign_in/code") |> html_response(200) =~ "nobody@emisar.test"
    end

    test "wrong codes re-render the form and start no session", %{conn: conn, staff: staff} do
      conn = request_code(conn, staff.email)
      code = emailed_code()
      wrong_otp = if Fixtures.Admin.totp_code(staff) == "000000", do: "111111", else: "000000"

      conn = submit_codes(conn, code, wrong_otp)

      assert html_response(conn, 200) =~ "Check both and try again."
      assert get_session(conn, :staff_token) == nil
    end

    test "a locked login says so once the emailed code is right", %{conn: conn, staff: staff} do
      Fixtures.Admin.update_staff(staff, failed_mfa_attempts: 5)
      conn = request_code(conn, staff.email)
      code = emailed_code()

      conn = submit_codes(conn, code, Fixtures.Admin.totp_code(staff))

      assert html_response(conn, 200) =~ "locked this staff login"
      assert get_session(conn, :staff_token) == nil
    end

    test "a browser with no pending sign-in starts over", %{conn: conn, staff: staff} do
      request_code(build_conn(), staff.email)
      code = emailed_code()

      assert redirected_to(get(conn, ~p"/admin/sign_in/code")) == ~p"/admin/sign_in"

      assert redirected_to(submit_codes(conn, code, Fixtures.Admin.totp_code(staff))) ==
               ~p"/admin/sign_in"
    end

    test "a submission missing a code goes back to the form", %{conn: conn, staff: staff} do
      conn = request_code(conn, staff.email)

      conn = post(conn, ~p"/admin/sign_in/code", %{"sign_in" => %{"secret" => "ABC234"}})

      assert redirected_to(conn) == ~p"/admin/sign_in/code"
    end
  end

  describe "DELETE /admin/sign_out" do
    test "ends the session and drops the staff cookie, leaving the workspace cookie alone", %{
      conn: conn,
      staff: staff
    } do
      {conn, staff_session} = log_in_staff(conn, staff)

      conn = delete(conn, ~p"/admin/sign_out")

      assert redirected_to(conn) == ~p"/admin/sign_in"
      assert Admin.refresh_staff_session(staff_session) == {:error, :not_found}
      assert conn.resp_cookies["_emisar_staff"].max_age == 0
      refute Map.has_key?(conn.resp_cookies, "_emisar_web_key")
    end
  end
end
