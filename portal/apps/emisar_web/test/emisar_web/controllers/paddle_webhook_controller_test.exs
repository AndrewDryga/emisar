defmodule EmisarWeb.PaddleWebhookControllerTest do
  @moduledoc """
  Billing-state ingest from Paddle (`POST /webhooks/paddle`). This is
  real money, so the cases that matter are:

    * a valid delivery applies the subscription side effect (the right
      plan is written) and returns 200,
    * a missing signature is rejected (400) with no side effect,
    * a re-delivery of the same `event_id` is deduped — 200, applied
      exactly once,
    * a billing-disabled deployment (no webhook secret configured)
      short-circuits to 503 instead of raising.

  Signature note: the test/dev Paddle client
  (`Emisar.Billing.PaddleClient.Stub`) does NOT verify the HMAC — it
  just `Jason.decode`s the body and returns the event. So the
  controller's *present-but-wrong* signature branch can't be exercised
  here without the live client; only the *missing* signature branch
  (which short-circuits in the controller before the client is called)
  is. The HMAC math itself lives in `PaddleClient.Live.verify_signature/3`.
  """
  use EmisarWeb.ConnCase, async: true

  import Emisar.Fixtures

  alias Emisar.Billing
  alias Emisar.Billing.Subscription
  alias Emisar.Repo

  @secret "pdl_ntfset_whsec_test"
  @price_team "pri_team_test"

  # The controller reads the secret from app env (nil on the
  # EMISAR_DISABLE_BILLING deployment → 503). test.exs leaves it unset,
  # so set it for the suite and restore the prior value on exit.
  # `:paddle_price_ids` maps the webhook's price id back to a plan name
  # so the applied subscription lands on a deterministic plan.
  setup do
    prev_secret = Application.get_env(:emisar, :paddle_webhook_secret)
    prev_prices = Application.get_env(:emisar, :paddle_price_ids)

    Application.put_env(:emisar, :paddle_webhook_secret, @secret)
    Application.put_env(:emisar, :paddle_price_ids, %{"team" => @price_team})

    on_exit(fn ->
      restore(:paddle_webhook_secret, prev_secret)
      restore(:paddle_price_ids, prev_prices)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:emisar, key)
  defp restore(key, value), do: Application.put_env(:emisar, key, value)

  # An account with a Paddle customer attached — the webhook resolves the
  # account by `data.customer_id`, so without this the event is a no-op.
  defp account_with_customer(customer_id) do
    {_user, account, _subject} = owner_subject_fixture()

    {:ok, account} =
      account
      |> Ecto.Changeset.change(paddle_customer_id: customer_id)
      |> Repo.update()

    account
  end

  defp subscription_event(opts) do
    %{
      "event_id" => opts[:event_id] || "evt_#{System.unique_integer([:positive])}",
      "event_type" => opts[:event_type] || "subscription.created",
      "data" => %{
        "id" => opts[:subscription_id] || "sub_#{System.unique_integer([:positive])}",
        "customer_id" => opts[:customer_id],
        "status" => opts[:status] || "active",
        "items" => [%{"price" => %{"id" => opts[:price_id] || @price_team}}]
      }
    }
  end

  # Post a JSON body with a (stub-accepted) signature header. The stub
  # ignores the signature value, so any non-empty header passes the
  # controller's `get_req_header` guard and reaches the client.
  defp post_webhook(conn, body, signature \\ "ts=1;h1=deadbeef") do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("paddle-signature", signature)
    |> post(~p"/webhooks/paddle", Jason.encode!(body))
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
      Application.delete_env(:emisar, :paddle_webhook_secret)

      account = account_with_customer("ctm_disabled")
      event = subscription_event(customer_id: "ctm_disabled")

      conn = post_webhook(conn, event)

      assert json_response(conn, 503) == %{"error" => "billing_disabled"}
      assert subscription_for(account.id) == nil
    end
  end

  # Sanity: the public apply function the controller delegates to is
  # idempotent on its own, independent of the HTTP edge.
  describe "Billing.record_and_apply_event/3" do
    test "second call with the same event id reports :duplicate", %{conn: _conn} do
      account = account_with_customer("ctm_ctx")

      event =
        subscription_event(
          event_id: "evt_ctx",
          customer_id: "ctm_ctx",
          subscription_id: "sub_ctx"
        )

      assert :ok = Billing.record_and_apply_event("evt_ctx", "subscription.created", event)

      assert {:duplicate, "evt_ctx"} =
               Billing.record_and_apply_event("evt_ctx", "subscription.created", event)

      assert subscription_for(account.id).paddle_subscription_id == "sub_ctx"
    end
  end

  describe "unhandled event type" do
    test "a well-formed unmodeled event_type → 200 no-op, then dedups on redelivery", %{
      conn: conn
    } do
      # closes BILL-012-T01, BILL-012-T02
      # `apply_webhook_event(_event), do: :ok` accepts any type we don't model.
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

    @tag capture_log: true
    test "a body the client can't decode is rejected as invalid → 400" do
      # Direct controller call, skipping the endpoint: Plug.Parsers would
      # 400 unparseable JSON itself, so this is the only way to reach the
      # controller's own rejection branch — and the `read_body/1` fallback
      # (no CachedBodyReader ran, so `assigns[:raw_body]` is unset).
      conn =
        build_conn(:post, "/webhooks/paddle", "not-json{{")
        |> put_req_header("paddle-signature", "ts=1;h1=deadbeef")
        |> EmisarWeb.PaddleWebhookController.call(EmisarWeb.PaddleWebhookController.init(:create))

      assert json_response(conn, 400) == %{"error" => "invalid"}
    end

    test "an apply failure → 500, logging field names but never payload values", %{conn: conn} do
      import ExUnit.CaptureLog

      _account = account_with_customer("ctm_apply_fail")

      event =
        subscription_event(
          event_id: "evt_apply_fail",
          customer_id: "ctm_apply_fail",
          subscription_id: "sub_apply_fail"
        )

      # Paddle owns `status` (open string), but the upsert requires it —
      # a null status is the natural in-the-wild apply failure.
      event = put_in(event, ["data", "status"], nil)

      log =
        capture_log(fn ->
          conn = post_webhook(conn, event)
          assert json_response(conn, 500) == %{"error" => "apply_failed"}
        end)

      assert log =~ "event_id=evt_apply_fail"
      assert log =~ "invalid_changeset[status]"
      # The redaction contract: field names only, no payload values.
      refute log =~ "ctm_apply_fail"
      refute log =~ "sub_apply_fail"
    end
  end
end
