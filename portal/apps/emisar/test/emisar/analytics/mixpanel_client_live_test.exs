defmodule Emisar.Analytics.MixpanelClient.LiveTest do
  use ExUnit.Case, async: true
  alias Emisar.Analytics.MixpanelClient.Live

  setup do
    Emisar.Config.put_override(:emisar, :mixpanel_token, "test-token")
  end

  test "returns an error instead of raising when a payload cannot be encoded" do
    assert {:error, {:encode, _reason}} =
             Live.track([%{"properties" => %{"unencodable" => self()}}])
  end
end
