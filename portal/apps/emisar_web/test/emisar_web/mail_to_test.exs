defmodule EmisarWeb.MailToTest do
  @moduledoc """
  Tests `EmisarWeb.MailTo`, the shared builder for prefilled contact links on
  marketing and authenticated console surfaces.
  """
  use ExUnit.Case, async: true
  alias EmisarWeb.MailTo

  describe "support/1" do
    test "prefills the subject/body and appends account/user context" do
      href =
        MailTo.support(
          subject: "Billing question - Test Co",
          context: %{
            account: "Test Co",
            account_id: "acc_123",
            user: "owner@example.com"
          }
        )

      assert href =~ "mailto:support@emisar.dev?"
      assert href =~ "%0A"
      refute href =~ "+"

      params = href |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert params["subject"] == "Billing question - Test Co"
      assert params["body"] =~ "Hi emisar team,"
      assert params["body"] =~ "What happened:"
      assert params["body"] =~ "Business impact:"
      assert params["body"] =~ "I have not included passwords, API keys, tokens"
      assert params["body"] =~ "Account: Test Co"
      assert params["body"] =~ "Account ID: acc_123"
      assert params["body"] =~ "User: owner@example.com"
    end
  end

  describe "sales/1 and security/1" do
    test "ask for the context each team needs without inviting secrets" do
      sales = MailTo.sales() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      security = MailTo.security() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert sales["subject"] == "Talk to sales · emisar"
      assert sales["body"] =~ "Current workflow or tooling:"
      assert sales["body"] =~ "Security, identity, or procurement requirements:"

      assert security["subject"] == "Security disclosure · emisar"
      assert security["body"] =~ "Security impact:"
      assert security["body"] =~ "Disclosure timeline or coordination needs:"
      assert security["body"] =~ "I have not included active credentials, secrets"
    end
  end

  describe "context/1" do
    test "omits missing assigns" do
      assert MailTo.context(%{}) == %{}

      assert MailTo.context(%{
               current_account: %{name: "Test Co", id: "acc_123"}
             }) == %{account: "Test Co", account_id: "acc_123"}
    end
  end
end
