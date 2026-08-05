defmodule EmisarWeb.PostmarkWebhookControllerTest do
  @moduledoc """
  The Postmark boundary: the Basic-Auth shared secret gates the endpoint, a
  recognized event maps onto the domain's deliverability command, and anything
  else is acknowledged without touching the suppression list. What a report
  DOES to that list is `Emisar.Mail`'s policy and is tested there.
  """
  use EmisarWeb.ConnCase, async: true
  import ExUnit.CaptureLog
  alias Emisar.Mail
  alias Emisar.Repo

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

  # An over-long Description is advisory prose the command bounds, so a real
  # bounce still lands instead of failing the write.
  test "an over-long bounce description still suppresses", %{conn: conn} do
    conn =
      conn
      |> auth()
      |> post_json(%{
        "RecordType" => "Bounce",
        "Type" => "HardBounce",
        "Email" => "verbose@example.com",
        "Inactive" => true,
        "Description" => String.duplicate("x", 5000)
      })

    assert json_response(conn, 200)["suppressed"] == true
    assert Mail.suppressed?("verbose@example.com")
  end

  test "a missing Basic-Auth header is rejected", %{conn: conn} do
    conn = post_json(conn, %{"RecordType" => "SpamComplaint", "Email" => "x@example.com"})

    assert json_response(conn, 401)
    refute Mail.suppressed?("x@example.com")
  end

  # The route is unauthenticated and publicly POSTable, so rejecting a request
  # must not write a log line an anonymous caller can amplify.
  test "a wrong Basic-Auth password is rejected without logging", %{conn: conn} do
    log =
      capture_log(fn ->
        response =
          conn
          |> auth("wrong-secret")
          |> post_json(%{"RecordType" => "SpamComplaint", "Email" => "y@example.com"})

        assert json_response(response, 401)
      end)

    # Asserted on THIS webhook's output, not on an empty string: `capture_log`
    # collects from the whole node, so an unrelated async test logging in the
    # same window failed this test with a line it never wrote.
    refute log =~ "postmark"
    refute log =~ "wrong-secret"
    refute log =~ "y@example.com"
    refute Mail.suppressed?("y@example.com")
  end

  # An event type the webhook doesn't act on (Delivery, Open, Click, …) is
  # acknowledged and never reaches the domain.
  test "an unsupported RecordType is a 200 no-op", %{conn: conn} do
    conn =
      conn
      |> auth()
      |> post_json(%{"RecordType" => "Delivery", "Email" => "delivered@example.com"})

    assert json_response(conn, 200) == %{"received" => true}
    refute Mail.suppressed?("delivered@example.com")
  end

  # A recognized event whose fields don't build a command — no address, or a
  # bounce that never says whether Postmark deactivated it — is acknowledged so
  # Postmark stops retrying a payload it can't fix.
  test "a bounce missing Email is a 200 no-op", %{conn: conn} do
    conn =
      conn
      |> auth()
      |> post_json(%{"RecordType" => "Bounce", "Type" => "HardBounce", "Inactive" => true})

    assert json_response(conn, 200) == %{"received" => true}
  end

  test "a bounce with a missing or non-boolean Inactive is a 200 no-op", %{conn: conn} do
    missing =
      conn
      |> auth()
      |> post_json(%{"RecordType" => "Bounce", "Email" => "no-flag@example.com"})

    assert json_response(missing, 200) == %{"received" => true}
    refute Mail.suppressed?("no-flag@example.com")

    non_boolean =
      conn
      |> auth()
      |> post_json(%{
        "RecordType" => "Bounce",
        "Email" => "string-flag@example.com",
        "Inactive" => "true"
      })

    assert json_response(non_boolean, 200) == %{"received" => true}
    refute Mail.suppressed?("string-flag@example.com")
  end

  # A provider identity we can't recognize as an address never reaches the
  # suppression list — a NUL especially, which Postgres cannot carry as a text
  # parameter at all and would fail the write at the wire protocol, turning a
  # broken payload into a permanent Postmark retry loop.
  test "a bounce whose Email is malformed is a 200 no-op", %{conn: conn} do
    for email <- ["no-at-sign", "nul\0@example.com", "bell\a@example.com"] do
      response =
        conn
        |> auth()
        |> post_json(%{
          "RecordType" => "Bounce",
          "Type" => "HardBounce",
          "Email" => email,
          "Inactive" => true
        })

      assert json_response(response, 200) == %{"received" => true}
    end

    refute Repo.one(Mail.Suppression)
  end

  # The endpoint bounds this unsigned, publicly-POSTable route at 64 KiB, so an
  # over-large body never reaches the controller: `Plug.Parsers` renders 413 and
  # re-raises, which `assert_error_sent` captures.
  test "a body over the endpoint's 64 KiB bound is refused and writes nothing", %{conn: conn} do
    body =
      Jason.encode!(%{
        "RecordType" => "Bounce",
        "Type" => "HardBounce",
        "Email" => "huge@example.com",
        "Inactive" => true,
        "Description" => String.duplicate("x", 70 * 1024)
      })

    assert byte_size(body) > 64 * 1024

    assert {413, _headers, _body} =
             assert_error_sent(413, fn ->
               conn
               |> auth()
               |> put_req_header("content-type", "application/json")
               |> post(~p"/webhooks/postmark", body)
             end)

    refute Repo.one(Mail.Suppression)
  end

  test "a malformed payload is a 200 no-op", %{conn: conn} do
    conn =
      conn
      |> auth()
      |> post_json(%{"totally" => "unexpected", "shape" => [1, 2, 3]})

    assert json_response(conn, 200) == %{"received" => true}
  end

  # Only the password is part of the shared secret; a different Basic-Auth
  # username with the correct password still verifies.
  test "the Basic-Auth username is ignored, only the password matters", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Basic " <> Base.encode64("anyone:#{@secret}"))
      |> post_json(%{"RecordType" => "SpamComplaint", "Email" => "user@example.com"})

    assert json_response(conn, 200)["suppressed"] == true
    assert Mail.suppressed?("user@example.com")
  end

  test "the webhook is disabled (503) when no secret is configured", %{conn: conn} do
    Emisar.Config.put_override(:emisar, :postmark_webhook_secret, nil)

    conn =
      conn
      |> auth()
      |> post_json(%{"RecordType" => "Bounce", "Email" => "x@example.com", "Inactive" => true})

    assert json_response(conn, 503) == %{"error" => "webhook_disabled"}
    refute Mail.suppressed?("x@example.com")
  end

  # The webhook rides the CSRF-free `:api` pipeline: Postmark POSTs cross-origin
  # and doesn't sign, so the Basic-Auth shared secret is the only authenticity
  # guarantee — a valid-secret POST with no CSRF token succeeds. We clear
  # `plug_skip_csrf_protection` (ConnTest sets it) to run the real pipeline;
  # `:api` carries no `:protect_from_forgery`, so the tokenless POST is accepted
  # on the secret alone (correct for a machine webhook, NOT a vuln).
  test "a valid-secret cross-origin POST with no CSRF token succeeds", %{conn: conn} do
    conn =
      conn
      |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
      |> auth()
      |> post_json(%{"RecordType" => "SpamComplaint", "Email" => "csrf-free@example.com"})

    assert json_response(conn, 200)["suppressed"] == true
    assert Mail.suppressed?("csrf-free@example.com")
  end
end
