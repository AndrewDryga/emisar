defmodule Emisar.MarketingTest do
  use Emisar.DataCase, async: true

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
  end
end
