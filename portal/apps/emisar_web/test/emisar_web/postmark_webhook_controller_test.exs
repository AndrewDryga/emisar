defmodule EmisarWeb.PostmarkWebhookControllerTest do
  @moduledoc """
  Postmark bounce/complaint ingest: a permanent bounce or spam complaint
  suppresses the address; transient bounces don't; the endpoint is gated by
  the Basic-Auth shared secret.
  """
  use EmisarWeb.ConnCase, async: true

  import ExUnit.CaptureLog

  alias Emisar.Mail
  alias Emisar.Mail.Suppression
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

  # closes OAUTH-009-T08 — an event type the webhook doesn't act on (Delivery,
  # Open, Click, …) is acknowledged and changes nothing.
  test "an unknown RecordType is a 200 no-op", %{conn: conn} do
    conn =
      conn
      |> auth()
      |> post_json(%{"RecordType" => "Delivery", "Email" => "delivered@example.com"})

    assert json_response(conn, 200) == %{"received" => true}
    refute Mail.suppressed?("delivered@example.com")
  end

  # closes OAUTH-009-T03 — bounce_detail formats the stored `detail` as
  # "Type: Description" when both are present, "Type" when only Type is, and nil
  # when neither is (each a separate guarded clause).
  test "bounce_detail formats Type/Description into the stored detail", %{conn: conn} do
    conn
    |> auth()
    |> post_json(%{
      "RecordType" => "Bounce",
      "Type" => "HardBounce",
      "Description" => "no such mailbox",
      "Email" => "both@example.com",
      "Inactive" => true
    })
    |> json_response(200)

    assert Repo.get_by!(Suppression, email: "both@example.com").detail ==
             "HardBounce: no such mailbox"

    conn
    |> auth()
    |> post_json(%{
      "RecordType" => "Bounce",
      "Type" => "HardBounce",
      "Email" => "typeonly@example.com",
      "Inactive" => true
    })
    |> json_response(200)

    assert Repo.get_by!(Suppression, email: "typeonly@example.com").detail == "HardBounce"

    conn
    |> auth()
    |> post_json(%{
      "RecordType" => "Bounce",
      "Email" => "neither@example.com",
      "Inactive" => true
    })
    |> json_response(200)

    assert Repo.get_by!(Suppression, email: "neither@example.com").detail == nil
  end

  # closes OAUTH-009-T07 — replaying the same permanent bounce is idempotent: both
  # POSTs are 200, and the address ends up suppressed in exactly one row (suppress/3
  # upserts on the email).
  test "a replayed permanent bounce is idempotent", %{conn: conn} do
    payload = %{
      "RecordType" => "Bounce",
      "Type" => "HardBounce",
      "Email" => "dup@example.com",
      "Inactive" => true,
      "Description" => "no such mailbox"
    }

    assert conn |> auth() |> post_json(payload) |> json_response(200)
    assert conn |> auth() |> post_json(payload) |> json_response(200)

    assert Mail.suppressed?("dup@example.com")
    assert Repo.aggregate(Suppression.Query.by_email("dup@example.com"), :count) == 1
  end

  # closes OAUTH-009-T09 — a permanent bounce with no Email falls through the
  # guarded clause (the `Email` pattern requires a binary): 200 no-op, nothing
  # suppressed.
  test "a bounce missing Email is a 200 no-op", %{conn: conn} do
    conn =
      conn
      |> auth()
      |> post_json(%{"RecordType" => "Bounce", "Type" => "HardBounce", "Inactive" => true})

    assert json_response(conn, 200) == %{"received" => true}
  end

  # closes OAUTH-009-T10 — an arbitrary/malformed JSON payload doesn't match any
  # event clause: 200 no-op, no crash, no suppression.
  test "a malformed payload is a 200 no-op", %{conn: conn} do
    conn =
      conn
      |> auth()
      |> post_json(%{"totally" => "unexpected", "shape" => [1, 2, 3]})

    assert json_response(conn, 200) == %{"received" => true}
  end

  # closes OAUTH-009-T14 — only the password is part of the shared secret; a
  # different Basic-Auth username with the correct password still verifies (200).
  test "the Basic-Auth username is ignored, only the password matters", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Basic " <> Base.encode64("anyone:#{@secret}"))
      |> post_json(%{"RecordType" => "SpamComplaint", "Email" => "user@example.com"})

    assert json_response(conn, 200)["suppressed"] == true
    assert Mail.suppressed?("user@example.com")
  end

  # closes OAUTH-009-T04 — with no shared secret configured the endpoint is
  # disabled: every request is 503, nothing is suppressed. Tests within a module
  # run sequentially, so deleting+restoring the env here can't race the others.
  test "the webhook is disabled (503) when no secret is configured", %{conn: conn} do
    prev = Application.get_env(:emisar, :postmark_webhook_secret)
    Application.delete_env(:emisar, :postmark_webhook_secret)
    on_exit(fn -> Application.put_env(:emisar, :postmark_webhook_secret, prev) end)

    conn =
      conn
      |> auth()
      |> post_json(%{"RecordType" => "Bounce", "Email" => "x@example.com", "Inactive" => true})

    assert json_response(conn, 503) == %{"error" => "webhook_disabled"}
    refute Mail.suppressed?("x@example.com")
  end

  # closes OAUTH-009-T05 — a failed suppression write is a 500 so Postmark
  # retries. Force the changeset to fail with a >1000-char detail (the bounce
  # Description flows into `detail`, which the Suppression changeset caps at
  # 1000) — no production code change needed.
  @tag capture_log: true
  test "a suppression write failure is a 500", %{conn: conn} do
    conn =
      conn
      |> auth()
      |> post_json(%{
        "RecordType" => "Bounce",
        "Type" => "HardBounce",
        "Email" => "fails@example.com",
        "Inactive" => true,
        "Description" => String.duplicate("x", 1001)
      })

    assert json_response(conn, 500) == %{"error" => "suppress_failed"}
    refute Mail.suppressed?("fails@example.com")
  end

  # closes OAUTH-009-T15 — the 500 suppress-failure log line carries `reason=`
  # only: the email address (PII) and the changeset are kept OUT of the drain.
  # Same forced-failure path as the 500 test (an over-1000-char detail).
  test "the suppress-failure log keeps the email address out of the drain", %{conn: conn} do
    email = "pii-leak@example.com"

    log =
      capture_log(fn ->
        conn
        |> auth()
        |> post_json(%{
          "RecordType" => "Bounce",
          "Type" => "HardBounce",
          "Email" => email,
          "Inactive" => true,
          "Description" => String.duplicate("x", 1001)
        })
        |> json_response(500)
      end)

    assert log =~ "postmark webhook suppress failed"
    assert log =~ "reason=hard_bounce"
    # The address (PII) and the raw changeset are never echoed into logs.
    refute log =~ email
    refute log =~ "changeset"
  end

  # closes OAUTH-009-T16 — the webhook rides the CSRF-free `:api` pipeline:
  # Postmark POSTs cross-origin and doesn't sign, so the Basic-Auth shared secret
  # is the only authenticity guarantee — a valid-secret POST with no CSRF token
  # succeeds. We clear `plug_skip_csrf_protection` (ConnTest sets it) to run the
  # real pipeline; `:api` carries no `:protect_from_forgery`, so the tokenless
  # POST is accepted on the secret alone (correct for a machine webhook, NOT a vuln).
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
