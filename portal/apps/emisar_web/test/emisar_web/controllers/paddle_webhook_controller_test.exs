defmodule EmisarWeb.PaddleWebhookControllerTest do
  @moduledoc """
  Billing-state ingest from Paddle (`POST /webhooks/paddle`). This is
  real money, so the cases that matter are:

    * a valid delivery applies the subscription side effect (the right
      plan is written) and returns 200,
    * a missing or unverifiable signature is rejected (400) with no side
      effect,
    * a re-delivery of the same `event_id` is deduped — 200, applied
      exactly once,
    * a billing-disabled deployment (no webhook secret configured)
      short-circuits to 503 instead of raising.

  Signature note: the test/dev Paddle client
  (`Emisar.Billing.PaddleClient.Stub`) does NOT verify the HMAC — it
  just `Jason.decode`s the body and returns the event. A test that needs
  the *present-but-wrong* signature branch binds
  `Emisar.Billing.PaddleClient.Live` for its own process instead; its
  webhook verification is pure HMAC math and makes no HTTP request.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Billing
  alias Emisar.Billing.Subscription
  alias Emisar.Repo

  @secret "pdl_ntfset_whsec_test"
  @price_team "pri_team_test"

  # Billing reads the secret from app env (nil on the
  # EMISAR_DISABLE_BILLING deployment → 503). test.exs leaves it unset,
  # so set it for every test in this file.
  setup do
    Emisar.Config.put_override(:emisar, :paddle_webhook_secret, @secret)
    :ok
  end

  # An account with a Paddle customer attached — the webhook resolves the
  # account by `data.customer_id`, so without this the event is a no-op.
  defp account_with_customer(customer_id) do
    Fixtures.Accounts.create_account(paddle_customer_id: customer_id)
  end

  defp subscription_event(opts) do
    %{
      "event_id" => opts[:event_id] || "evt_#{System.unique_integer([:positive])}",
      "event_type" => opts[:event_type] || "subscription.created",
      "data" => %{
        "id" => opts[:subscription_id] || "sub_#{System.unique_integer([:positive])}",
        "customer_id" => opts[:customer_id],
        "status" => opts[:status] || "active",
        # Real payloads embed the full product per item — its name identifies
        # the plan, so the applied subscription lands on a deterministic plan.
        "items" => [
          %{
            "price" => %{"id" => opts[:price_id] || @price_team},
            "product" => %{"id" => "pro_test_01", "name" => "team", "custom_data" => nil}
          }
        ]
      }
    }
  end

  # Post a JSON body with a (stub-accepted) signature header. The stub
  # ignores the signature value, so any single header passes the
  # controller's one-header guard and reaches billing.
  defp post_webhook(conn, body, signature \\ "ts=1;h1=deadbeef") do
    post_raw_webhook(conn, Jason.encode!(body), signature)
  end

  defp post_raw_webhook(conn, payload, signature) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("paddle-signature", signature)
    |> post(~p"/webhooks/paddle", payload)
  end

  defp post_duplicate_signature_webhook(conn, body) do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("paddle-signature", "ts=1;h1=first")

    conn = Map.update!(conn, :req_headers, &[{"paddle-signature", "ts=1;h1=second"} | &1])

    post(conn, ~p"/webhooks/paddle", Jason.encode!(body))
  end

  # A header the live client accepts: HMAC-SHA256 over `<ts>:<raw_body>`.
  defp signature_for(payload, timestamp) do
    digest = :crypto.mac(:hmac, :sha256, @secret, "#{timestamp}:#{payload}")

    "ts=#{timestamp};h1=" <> Base.encode16(digest, case: :lower)
  end

  defp subscription_for(account_id) do
    Subscription.Query.all()
    |> Subscription.Query.by_account_id(account_id)
    |> Repo.peek()
  end

  describe "valid event" do
    test "applies the subscription side effect and returns 200", %{conn: conn} do
      account = account_with_customer("ctm_valid")

      event =
        subscription_event(
          customer_id: "ctm_valid",
          subscription_id: "sub_valid",
          price_id: @price_team,
          status: "active"
        )

      conn = post_webhook(conn, event)

      assert json_response(conn, 200) == %{"received" => true}

      # Side effect: the subscription row exists, on the plan the price id
      # maps to, with the Paddle ids mirrored.
      subscription = subscription_for(account.id)
      assert subscription.plan == "team"
      assert subscription.status == "active"
      assert subscription.paddle_subscription_id == "sub_valid"
      assert subscription.paddle_price_id == @price_team
    end
  end

  describe "signature gate" do
    test "missing paddle-signature header → 400, no side effect", %{conn: conn} do
      account = account_with_customer("ctm_nosig")
      event = subscription_event(customer_id: "ctm_nosig")

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/webhooks/paddle", Jason.encode!(event))

      assert json_response(conn, 400) == %{"error" => "missing_signature"}
      assert subscription_for(account.id) == nil
    end

    test "duplicate signature headers are rejected without crashing or applying", %{conn: conn} do
      account = account_with_customer("ctm_duplicate_signature")
      event = subscription_event(customer_id: "ctm_duplicate_signature")

      conn = post_duplicate_signature_webhook(conn, event)

      assert json_response(conn, 400) == %{"error" => "invalid"}
      assert subscription_for(account.id) == nil
    end

    test "invalid signature leaves the exact raw event retryable with a valid signature", %{
      conn: conn
    } do
      import ExUnit.CaptureLog

      # The stub accepts any signature, so reaching real verification means
      # binding the live client for this process — its webhook verification
      # is pure HMAC math and makes no HTTP request.
      Emisar.Config.put_override(:emisar, :paddle_client, Emisar.Billing.PaddleClient.Live)

      account = account_with_customer("ctm_badsig")
      event = subscription_event(customer_id: "ctm_badsig")
      payload = Jason.encode!(event)
      timestamp = System.system_time(:second)
      invalid_signature = "ts=#{timestamp};h1=deadbeef"
      valid_signature = signature_for(payload, timestamp)

      log =
        capture_log(fn ->
          invalid = post_raw_webhook(conn, payload, invalid_signature)
          assert json_response(invalid, 400) == %{"error" => "invalid"}
          assert subscription_for(account.id) == nil

          accepted = post_raw_webhook(conn, payload, valid_signature)
          assert json_response(accepted, 200) == %{"received" => true}

          duplicate = post_raw_webhook(conn, payload, valid_signature)
          assert json_response(duplicate, 200) == %{"received" => true, "duplicate" => true}
        end)

      assert subscription_for(account.id).status == "active"
      refute log =~ "ctm_badsig"
      refute log =~ invalid_signature
      refute log =~ valid_signature
      refute log =~ @secret
    end
  end

  describe "idempotency" do
    test "re-delivery of the same event_id is deduped — applied once", %{conn: conn} do
      account = account_with_customer("ctm_dup")

      event =
        subscription_event(
          event_id: "evt_dup_1",
          customer_id: "ctm_dup",
          subscription_id: "sub_dup",
          status: "active"
        )

      first = post_webhook(conn, event)
      assert json_response(first, 200) == %{"received" => true}

      # Same event id re-delivered (Paddle retries any non-2xx). The
      # controller replies 200 with a duplicate marker and does NOT
      # re-apply.
      second = post_webhook(conn, event)
      assert json_response(second, 200) == %{"received" => true, "duplicate" => true}

      # Exactly one subscription row — the dup was not applied a second
      # time. (The 200 + `duplicate: true` above is the dedup signal; the
      # single row is the proof the side effect ran exactly once.)
      assert subscription_for(account.id).paddle_subscription_id == "sub_dup"

      count =
        Subscription.Query.all()
        |> Subscription.Query.by_account_id(account.id)
        |> Repo.aggregate(:count, :id)

      assert count == 1
    end

    test "a status change under a NEW event_id does apply", %{conn: conn} do
      account = account_with_customer("ctm_seq")

      created =
        subscription_event(
          event_id: "evt_seq_created",
          event_type: "subscription.created",
          customer_id: "ctm_seq",
          subscription_id: "sub_seq",
          status: "active"
        )

      assert json_response(post_webhook(conn, created), 200)
      assert subscription_for(account.id).status == "active"

      canceled =
        subscription_event(
          event_id: "evt_seq_canceled",
          event_type: "subscription.canceled",
          customer_id: "ctm_seq",
          subscription_id: "sub_seq",
          status: "canceled"
        )

      assert json_response(post_webhook(conn, canceled), 200)
      assert subscription_for(account.id).status == "canceled"
    end
  end

  describe "billing-disabled deployment" do
    test "no webhook secret configured → 503, never reaches the client", %{conn: conn} do
      Emisar.Config.put_override(:emisar, :paddle_webhook_secret, nil)

      account = account_with_customer("ctm_disabled")
      event = subscription_event(customer_id: "ctm_disabled")

      conn = post_webhook(conn, event)

      assert json_response(conn, 503) == %{"error" => "billing_disabled"}
      assert subscription_for(account.id) == nil
    end
  end

  # Sanity: the Billing ingest the controller delegates to verifies,
  # dedups, and applies on its own, independent of the HTTP edge.
  describe "ingest_paddle_webhook/2" do
    test "second call with the same event id reports :duplicate" do
      account = account_with_customer("ctm_ctx")

      event =
        subscription_event(
          event_id: "evt_ctx",
          customer_id: "ctm_ctx",
          subscription_id: "sub_ctx"
        )

      payload = Jason.encode!(event)
      signature = "ts=1;h1=deadbeef"

      assert Billing.ingest_paddle_webhook(payload, signature) == :ok
      assert Billing.ingest_paddle_webhook(payload, signature) == {:duplicate, "evt_ctx"}

      assert subscription_for(account.id).paddle_subscription_id == "sub_ctx"
    end
  end

  describe "unhandled event type" do
    test "a well-formed unmodeled event_type → 200 no-op, then dedups on redelivery", %{
      conn: conn
    } do
      # Unmodeled event types commit their receipt without a subscription write.
      # No subscription is written, the dedup row commits (the no-op IS a
      # success), so a redelivery of the same event_id returns the duplicate
      # marker without reprocessing.
      account = account_with_customer("ctm_unhandled")

      event = %{
        "event_id" => "evt_unhandled_http",
        "event_type" => "transaction.completed",
        "data" => %{"id" => "txn_http", "customer_id" => "ctm_unhandled"}
      }

      first = post_webhook(conn, event)
      assert json_response(first, 200) == %{"received" => true}

      # No subscription mirror created by the no-op.
      assert subscription_for(account.id) == nil

      # Redelivery dedups (the dedup row committed for the successful no-op).
      second = post_webhook(conn, event)
      assert json_response(second, 200) == %{"received" => true, "duplicate" => true}

      assert subscription_for(account.id) == nil
    end
  end

  describe "malformed + failing events" do
    test "a decodable event without event_id/event_type is malformed → 400", %{conn: conn} do
      conn = post_webhook(conn, %{"hello" => "world"})

      assert json_response(conn, 400) == %{"error" => "malformed_event"}
    end

    test "an event with non-string identity fields is malformed before billing", %{conn: conn} do
      conn =
        post_webhook(conn, %{
          "event_id" => %{"nested" => "value"},
          "event_type" => "subscription.created"
        })

      assert json_response(conn, 400) == %{"error" => "malformed_event"}
    end

    @tag capture_log: true
    test "a body the client can't decode is rejected as invalid → 400" do
      # Direct controller call, skipping the endpoint: Plug.Parsers would
      # 400 unparseable JSON itself, so this is the only way to reach
      # billing's verification-failure branch — and the `read_body/1`
      # fallback (no CachedBodyReader ran, so `assigns[:raw_body]` is unset).
      conn =
        build_conn(:post, "/webhooks/paddle", "not-json{{")
        |> put_req_header("paddle-signature", "ts=1;h1=deadbeef")
        |> EmisarWeb.PaddleWebhookController.call(EmisarWeb.PaddleWebhookController.init(:create))

      assert json_response(conn, 400) == %{"error" => "invalid"}
    end

    test "a decode failure after a valid signature never logs the raw body" do
      import ExUnit.CaptureLog

      # The stub reports its own `:invalid_payload` atom, so reaching the
      # `Jason.DecodeError` — which carries the raw bytes — means binding the
      # live client and signing a body that passes the HMAC gate.
      Emisar.Config.put_override(:emisar, :paddle_client, Emisar.Billing.PaddleClient.Live)

      payload = ~s({"event_id":"evt_decode_fail","customer_id":"ctm_decode_leak_marker"{{)
      signature = signature_for(payload, System.system_time(:second))

      log =
        capture_log(fn ->
          conn =
            build_conn(:post, "/webhooks/paddle", payload)
            |> put_req_header("paddle-signature", signature)
            |> EmisarWeb.PaddleWebhookController.call(
              EmisarWeb.PaddleWebhookController.init(:create)
            )

          assert json_response(conn, 400) == %{"error" => "invalid"}
        end)

      refute log =~ "ctm_decode_leak_marker"
    end

    test "a malformed lifecycle event → 500, logging a safe category but never payload values", %{
      conn: conn
    } do
      import ExUnit.CaptureLog

      account_with_customer("ctm_apply_fail")

      event =
        subscription_event(
          event_id: "evt_apply_fail",
          customer_id: "ctm_apply_fail",
          subscription_id: "sub_apply_fail"
        )

      # Paddle owns `status` (open string), but every lifecycle payload requires
      # a binary value. Reject the malformed envelope before any mirror write.
      event = put_in(event, ["data", "status"], nil)

      log =
        capture_log(fn ->
          conn = post_webhook(conn, event)
          assert json_response(conn, 500) == %{"error" => "apply_failed"}
        end)

      assert log =~ "malformed_subscription"
      # The redaction contract: a fixed category only, no payload-derived values.
      refute log =~ "evt_apply_fail"
      refute log =~ "ctm_apply_fail"
      refute log =~ "sub_apply_fail"
    end
  end
end
