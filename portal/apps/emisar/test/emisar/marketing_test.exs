defmodule Emisar.MarketingTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Config, Users}
  alias Emisar.Marketing
  alias Emisar.Marketing.Signup

  describe "capture_signup/2" do
    test "stores a valid email with its source" do
      assert {:ok, %Signup{} = signup} =
               Marketing.capture_signup(%{email: "a@example.com", source: "footer"})

      assert signup.email == "a@example.com"
      assert signup.source == "footer"
    end

    test "trims surrounding whitespace" do
      assert {:ok, signup} = Marketing.capture_signup(%{email: "  b@example.com  "})
      assert signup.email == "b@example.com"
    end

    test "is idempotent — a repeat address updates the source, no duplicate row, no error" do
      assert {:ok, first} = Marketing.capture_signup(%{email: "c@example.com", source: "home"})

      assert {:ok, second} =
               Marketing.capture_signup(%{email: "c@example.com", source: "pricing"})

      assert first.id == second.id
      assert second.source == "pricing"
      assert Repo.aggregate(Signup, :count, :id) == 1
    end

    test "treats the email case-insensitively (citext) — no duplicate" do
      assert {:ok, _} = Marketing.capture_signup(%{email: "Dee@Example.com"})
      assert {:ok, _} = Marketing.capture_signup(%{email: "dee@example.com"})
      assert Repo.aggregate(Signup, :count, :id) == 1
    end

    test "rejects a malformed email" do
      assert {:error, changeset} = Marketing.capture_signup(%{email: "not-an-email"})
      assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)
    end

    test "requires an email" do
      assert {:error, changeset} = Marketing.capture_signup(%{source: "footer"})
      assert %{email: ["can't be blank"]} = errors_on(changeset)
    end

    test "bounds email and source input before persistence" do
      too_long_email = String.duplicate("a", 250) <> "@x.co"
      too_long_source = String.duplicate("s", 101)

      assert {:error, changeset} = Marketing.capture_signup(%{email: too_long_email})
      assert %{email: ["should be at most 254 character(s)"]} = errors_on(changeset)

      assert {:error, changeset} =
               Marketing.capture_signup(%{email: "source@example.com", source: too_long_source})

      assert %{source: ["should be at most 100 character(s)"]} = errors_on(changeset)
    end
  end

  describe "account_signed_up/2" do
    setup do
      parent = self()
      Config.put_override(:emisar, :x_ads_conversions, %{})

      Config.put_override(:emisar, :x_ads_conversion_sender, fn _config, event ->
        send(parent, {:x_ads_signup, event})
        :ok
      end)

      %{user: %Users.User{id: Ecto.UUID.generate(), email: "person@example.com"}}
    end

    test "sends only the click id, time, and opaque conversion id", %{user: user} do
      attribution = %{campaign: %{"utm_source" => "x"}, x_click_id: "click-123"}

      assert :ok = Marketing.account_signed_up(user, attribution)

      assert_receive {:x_ads_signup, event}
      assert event.x_click_id == "click-123"
      assert {:ok, _time, 0} = DateTime.from_iso8601(event.conversion_time)
      assert event.conversion_time =~ ~r/\.\d{3}Z$/
      assert byte_size(event.conversion_id) == 64
      refute inspect(event) =~ user.email
      refute inspect(event) =~ user.id
    end

    test "sends nothing without an eligible click id", %{user: user} do
      assert :ok = Marketing.account_signed_up(user, %{campaign: %{}})
      refute_receive {:x_ads_signup, _event}
    end

    test "sends nothing when the provider is unconfigured", %{user: user} do
      Config.put_override(:emisar, :x_ads_conversions, nil)
      attribution = %{campaign: %{}, x_click_id: "disabled-click"}

      assert :ok = Marketing.account_signed_up(user, attribution)
      refute_receive {:x_ads_signup, _event}
    end
  end
end
