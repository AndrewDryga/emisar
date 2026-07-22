defmodule Emisar.Marketing.ConversionsTest do
  use ExUnit.Case, async: true
  alias Emisar.{Marketing, Users}

  setup do
    start_supervised!({Task.Supervisor, name: EmisarWeb.TaskSupervisor})
    parent = self()
    Emisar.Config.put_override(:emisar, :x_ads_conversions, %{})

    Emisar.Config.put_override(:emisar, :x_ads_conversion_sender, fn _config, event ->
      send(parent, {:x_ads_signup, event})
      :ok
    end)

    :ok
  end

  test "sends only the click id, time, and opaque conversion id" do
    user = %Users.User{id: Ecto.UUID.generate(), email: "person@example.com"}

    assert :ok =
             Marketing.Conversions.account_signed_up(user, %{
               campaign: %{"utm_source" => "x"},
               x_click_id: "click-123"
             })

    assert_receive {:x_ads_signup, event}
    assert event.x_click_id == "click-123"
    assert {:ok, _time, 0} = DateTime.from_iso8601(event.conversion_time)
    assert event.conversion_time =~ ~r/\.\d{3}Z$/
    assert byte_size(event.conversion_id) == 64
    refute inspect(event) =~ user.email
    refute inspect(event) =~ user.id
  end

  test "does nothing without a click id or configuration" do
    user = %Users.User{id: Ecto.UUID.generate()}

    assert :ok = Marketing.Conversions.account_signed_up(user, %{campaign: %{}})
    refute_receive {:x_ads_signup, _event}

    Emisar.Config.put_override(:emisar, :x_ads_conversions, nil)

    assert :ok =
             Marketing.Conversions.account_signed_up(user, %{
               campaign: %{},
               x_click_id: "disabled-click"
             })

    refute_receive {:x_ads_signup, _event}
  end
end
