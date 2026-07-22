defmodule Emisar.Analytics.MixpanelClient.LiveTest do
  use ExUnit.Case, async: false
  alias Emisar.Analytics.MixpanelClient.Live

  @config_key :mixpanel_token

  setup do
    Emisar.Config.put_override(:emisar, @config_key, "test-token")
  end

  test "returns an error instead of raising when a payload cannot be encoded" do
    assert {:error, {:encode, _reason}} =
             Live.track([%{"properties" => %{"unencodable" => self()}}])
  end
end
