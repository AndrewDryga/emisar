defmodule Emisar.Billing.PaddleClientLiveTest.RecordingHTTP do
  def request(request, pool, opts) do
    send(self(), {:paddle_http_request, request, pool, opts})
    Emisar.Config.fetch_env!(:emisar, :paddle_http_response)
  end
end

defmodule Emisar.Billing.PaddleClientLiveTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Config, Fixtures, Repo}
  alias Emisar.Billing.PaddleClient.Live
  alias Emisar.Billing.PaddleClientLiveTest.RecordingHTTP

  @secret "pdl_ntfset_whsec_test"

  describe "cancel_subscription/1" do
    setup do
      Config.put_override(:emisar, :paddle_api_key, "pdl_sdbx_test")
      Config.put_override(:emisar, Live, http_client: RecordingHTTP)
      :ok
    end

    test "posts an immediate cancellation and confirms the returned subscription" do
      subscription = %{"id" => "sub_example", "status" => "canceled"}
      response = %Finch.Response{status: 200, body: Jason.encode!(%{"data" => subscription})}
      Config.put_override(:emisar, :paddle_http_response, {:ok, response})

      assert Live.cancel_subscription("sub_example") == {:ok, subscription}
      assert_received {:paddle_http_request, request, Emisar.Finch, [receive_timeout: 8_000]}
      assert request.method == "POST"
      assert request.scheme == :https
      assert request.host == "sandbox-api.paddle.com"
      assert request.path == "/subscriptions/sub_example/cancel"
      assert Jason.decode!(request.body) == %{"effective_from" => "immediately"}
      assert {"authorization", "Bearer pdl_sdbx_test"} in request.headers
      assert {"paddle-version", "1"} in request.headers
    end

    test "refuses success-shaped replies without the exact canceled subscription" do
      for data <- [
            %{
              "id" => "sub_example",
              "status" => "active",
              "scheduled_change" => %{"action" => "cancel"}
            },
            %{"id" => "sub_example", "status" => "paused"},
            %{"id" => "sub_other", "status" => "canceled"},
            %{"status" => "canceled"},
            nil
          ] do
        response = %Finch.Response{status: 200, body: Jason.encode!(%{"data" => data})}
        Config.put_override(:emisar, :paddle_http_response, {:ok, response})
        assert Live.cancel_subscription("sub_example") == {:error, :cancellation_not_confirmed}
      end
    end

    test "preserves HTTP, transport, and JSON failures" do
      response = %Finch.Response{status: 409, body: "cannot cancel"}
      Config.put_override(:emisar, :paddle_http_response, {:ok, response})
      assert Live.cancel_subscription("sub_example") == {:error, {:http, 409, "cannot cancel"}}

      Config.put_override(:emisar, :paddle_http_response, {:error, :timeout})
      assert Live.cancel_subscription("sub_example") == {:error, :timeout}

      response = %Finch.Response{status: 200, body: "not JSON"}
      Config.put_override(:emisar, :paddle_http_response, {:ok, response})
      assert {:error, %Jason.DecodeError{}} = Live.cancel_subscription("sub_example")
    end

    test "account closure waits for confirmed provider cancellation" do
      for status <- ["active", "paused", "canceled"] do
        {_user, account, subject} = Fixtures.Subjects.owner_subject()
        subscription_id = "sub_#{account.id}"

        Fixtures.Accounts.create_subscription(account, "team",
          paddle_subscription_id: subscription_id
        )

        Config.put_override(:emisar, :paddle_client, Live)

        response = %Finch.Response{
          status: 200,
          body: Jason.encode!(%{"data" => %{"id" => subscription_id, "status" => status}})
        }

        Config.put_override(:emisar, :paddle_http_response, {:ok, response})

        if status == "canceled" do
          assert {:ok, closed} = Accounts.close_account(account.id, "Customer left", subject)
          assert closed.deleted_at
        else
          assert Accounts.close_account(account.id, "Customer left", subject) ==
                   {:error, {:paddle_cancel_failed, :cancellation_not_confirmed}}

          assert is_nil(Repo.reload!(account).deleted_at)
        end

        assert_received {:paddle_http_request, request, Emisar.Finch, _opts}
        assert request.method == "POST"
        assert request.path == "/subscriptions/#{subscription_id}/cancel"
      end
    end
  end

  describe "construct_webhook_event/3" do
    test "verifies a fresh signature and decodes the signed bytes" do
      timestamp = System.system_time(:second)

      payload =
        ~S({"event_type": "subscription.created", "event_id": "evt_1", "message": "signed \u0062ytes"})

      signature = signature_for(payload, timestamp, @secret)

      assert Live.construct_webhook_event(payload, signature, @secret) ==
               {:ok,
                %{
                  "event_id" => "evt_1",
                  "event_type" => "subscription.created",
                  "message" => "signed bytes"
                }}
    end

    test "rejects a signature verified with the wrong secret" do
      timestamp = System.system_time(:second)
      payload = ~s({"event_type":"subscription.created","event_id":"evt_1"})
      signature = signature_for(payload, timestamp, @secret)

      assert Live.construct_webhook_event(payload, signature, "wrong-secret") ==
               {:error, :signature_mismatch}
    end

    test "rejects a body tampered after signing" do
      timestamp = System.system_time(:second)
      signed_payload = ~s({"event_type":"subscription.created","event_id":"evt_1"})
      tampered_payload = ~s({"event_type":"subscription.created","event_id":"evt_2"})
      signature = signature_for(signed_payload, timestamp, @secret)

      assert Live.construct_webhook_event(tampered_payload, signature, @secret) ==
               {:error, :signature_mismatch}
    end

    test "rejects missing and malformed signature headers" do
      timestamp = System.system_time(:second)
      payload = ~s({"event_type":"subscription.created","event_id":"evt_1"})

      for signature <- [
            "",
            "ts=#{timestamp}",
            "not-a-paddle-signature",
            "ts=not-a-timestamp;h1=deadbeef",
            "ts=#{timestamp};h1"
          ] do
        assert Live.construct_webhook_event(payload, signature, @secret) ==
                 {:error, :signature_mismatch}
      end
    end

    test "rejects a correctly signed payload older than the replay window" do
      timestamp = System.system_time(:second) - 301
      payload = ~s({"event_type":"subscription.created","event_id":"evt_1"})
      signature = signature_for(payload, timestamp, @secret)

      assert Live.construct_webhook_event(payload, signature, @secret) ==
               {:error, :timestamp_too_old}
    end
  end

  describe "parse_subscription_page/1" do
    test "extracts an advancing cursor only while Paddle reports more pages" do
      assert Live.parse_subscription_page(%{
               "data" => [%{"id" => "sub_one"}],
               "meta" => %{
                 "pagination" => %{
                   "has_more" => true,
                   "next" => "https://api.paddle.com/subscriptions?after=sub_one&per_page=1"
                 }
               }
             }) ==
               {:ok, %{subscriptions: [%{"id" => "sub_one"}], next_after: "sub_one"}}

      assert Live.parse_subscription_page(%{
               "data" => [],
               "meta" => %{
                 "pagination" => %{
                   "has_more" => false,
                   "next" => "https://api.paddle.com/subscriptions?after=ignored"
                 }
               }
             }) == {:ok, %{subscriptions: [], next_after: nil}}
    end

    test "fails closed when has_more lacks a usable cursor" do
      for pagination <- [
            %{"has_more" => true},
            %{"has_more" => true, "next" => ""},
            %{"has_more" => true, "next" => "https://api.paddle.com/subscriptions?after="},
            %{"has_more" => true, "next" => "https://api.paddle.com/subscriptions"}
          ] do
        assert Live.parse_subscription_page(%{
                 "data" => [],
                 "meta" => %{"pagination" => pagination}
               }) == {:error, :malformed_subscription_page}
      end
    end
  end

  describe "build_update_subscription_request/2" do
    test "builds the versioned PATCH with the complete caller-supplied item set" do
      Emisar.Config.put_override(:emisar, :paddle_api_key, "pdl_sdbx_test")

      attrs = %{
        "items" => [
          %{"price_id" => "pri_team", "quantity" => 3},
          %{"price_id" => "pri_addon", "quantity" => 1}
        ],
        "proration_billing_mode" => "prorated_next_billing_period",
        "on_payment_failure" => "prevent_change"
      }

      request = Live.build_update_subscription_request("sub_team", attrs)

      assert request.method == "PATCH"
      assert request.scheme == :https
      assert request.host == "sandbox-api.paddle.com"
      assert request.path == "/subscriptions/sub_team"
      assert {"paddle-version", "1"} in request.headers
      assert Jason.decode!(request.body) == attrs
    end
  end

  defp signature_for(payload, timestamp, secret) do
    signed_payload = "#{timestamp}:#{payload}"
    digest = :crypto.mac(:hmac, :sha256, secret, signed_payload)

    "ts=#{timestamp};h1=" <> Base.encode16(digest, case: :lower)
  end
end
