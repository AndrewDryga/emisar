defmodule Emisar.Analytics.MixpanelClient.LiveTest do
  use ExUnit.Case, async: false
  alias Emisar.Analytics.MixpanelClient.Live

  @config_key :mixpanel_token
  @unset :unset

  setup do
    original = Application.get_env(:emisar, @config_key, @unset)
    Application.put_env(:emisar, @config_key, "test-token")

    on_exit(fn ->
      if original == @unset,
        do: Application.delete_env(:emisar, @config_key),
        else: Application.put_env(:emisar, @config_key, original)
    end)
  end

  test "returns an error instead of raising when a payload cannot be encoded" do
    assert {:error, {:encode, _reason}} =
             Live.track([%{"properties" => %{"unencodable" => self()}}])
  end
end
