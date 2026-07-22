defmodule Emisar.Marketing.XClientTest do
  use ExUnit.Case, async: true
  alias Emisar.Marketing.XClient

  test "builds the OAuth-signed X conversion request" do
    config = %{
      consumer_key: "consumer-key",
      consumer_secret: "consumer-secret",
      access_token: "access-token",
      access_token_secret: "access-secret",
      pixel_id: "re0km",
      event_id: "tw-re0km-re0v9"
    }

    event = %{
      conversion_id: String.duplicate("a", 64),
      conversion_time: "2026-07-21T08:36:02.206Z",
      x_click_id: "x-click-123"
    }

    assert {:ok, request} = XClient.build_request(config, event)
    assert request.method == "POST"
    assert request.host == "ads-api.x.com"
    assert request.path == "/12/measurement/conversions/re0km"

    assert {"authorization", "OAuth " <> authorization} =
             List.keyfind(request.headers, "authorization", 0)

    assert authorization =~ ~s(oauth_consumer_key="consumer-key")
    refute authorization =~ "consumer-secret"
    refute authorization =~ "access-secret"

    assert {:ok,
            %{
              "conversions" => [
                %{
                  "conversion_id" => conversion_id,
                  "event_id" => "tw-re0km-re0v9",
                  "identifiers" => [%{"twclid" => "x-click-123"}]
                }
              ]
            }} = Jason.decode(request.body)

    assert conversion_id == event.conversion_id
  end
end
