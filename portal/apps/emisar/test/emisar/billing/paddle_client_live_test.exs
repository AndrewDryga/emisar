defmodule Emisar.Billing.PaddleClientLiveTest do
  use ExUnit.Case, async: true
  alias Emisar.Billing.PaddleClient.Live

  @secret "pdl_ntfset_whsec_test"

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

  defp signature_for(payload, timestamp, secret) do
    signed_payload = "#{timestamp}:#{payload}"
    digest = :crypto.mac(:hmac, :sha256, secret, signed_payload)

    "ts=#{timestamp};h1=" <> Base.encode16(digest, case: :lower)
  end
end
