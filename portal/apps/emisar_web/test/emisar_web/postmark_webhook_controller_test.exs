defmodule EmisarWeb.PostmarkWebhookControllerTest do
  @moduledoc """
  Postmark bounce/complaint ingest: a permanent bounce or spam complaint
  suppresses the address; transient bounces don't; the endpoint is gated by
  the Basic-Auth shared secret.
  """
  use EmisarWeb.ConnCase, async: true

  alias Emisar.Mail

  # Matches config/test.exs :postmark_webhook_secret.
  @secret "pm_webhook_test"

  defp auth(conn, password \\ @secret),
    do: put_req_header(conn, "authorization", "Basic " <> Base.encode64("postmark:#{password}"))

  # Postmark posts JSON, so send a JSON body (not form params) to keep the
  # `Inactive` boolean a boolean rather than the string "true".
  defp post_json(conn, payload) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/webhooks/postmark", Jason.encode!(payload))
  end

  test "a permanent bounce suppresses the address", %{conn: conn} do
    conn =
      conn
      |> auth()
      |> post_json(%{
        "RecordType" => "Bounce",
        "Type" => "HardBounce",
        "Email" => "dead@example.com",
        "Inactive" => true,
        "Description" => "no such mailbox"
      })

    assert json_response(conn, 200)["suppressed"] == true
    assert Mail.suppressed?("dead@example.com")
  end

  test "a spam complaint suppresses the address", %{conn: conn} do
    conn =
      conn
      |> auth()
      |> post_json(%{"RecordType" => "SpamComplaint", "Email" => "angry@example.com"})

    assert json_response(conn, 200)["suppressed"] == true
    assert Mail.suppressed?("angry@example.com")
  end

  test "a transient bounce does NOT suppress", %{conn: conn} do
    conn =
      conn
      |> auth()
      |> post_json(%{
        "RecordType" => "Bounce",
        "Type" => "SoftBounce",
        "Email" => "slow@example.com",
        "Inactive" => false
      })

    assert json_response(conn, 200) == %{"received" => true}
    refute Mail.suppressed?("slow@example.com")
  end

  test "a missing Basic-Auth header is rejected", %{conn: conn} do
    conn = post_json(conn, %{"RecordType" => "SpamComplaint", "Email" => "x@example.com"})

    assert json_response(conn, 401)
    refute Mail.suppressed?("x@example.com")
  end

  test "a wrong Basic-Auth password is rejected", %{conn: conn} do
    conn =
      conn
      |> auth("wrong-secret")
      |> post_json(%{"RecordType" => "SpamComplaint", "Email" => "y@example.com"})

    assert json_response(conn, 401)
    refute Mail.suppressed?("y@example.com")
  end
end
