defmodule Emisar.Accounts.Account.ChangesetTest do
  use Emisar.DataCase, async: true
  alias Emisar.Accounts.Account
  alias Emisar.Fixtures

  describe "create/1" do
    test "is valid with default attrs" do
      assert changeset().valid?
    end

    test "validates account name length (1..80 inclusive)" do
      assert changeset(name: "a").valid?
      assert changeset(name: String.duplicate("a", 80)).valid?

      assert "can't be blank" in errors_on(changeset(name: "")).name

      too_long = changeset(name: String.duplicate("a", 81))
      assert "should be at most 80 character(s)" in errors_on(too_long).name
    end

    test "validates slug format" do
      assert changeset(slug: "valid-slug-1").valid?

      assert "can't be blank" in errors_on(changeset(slug: "")).slug

      expected_error =
        "must be lowercase letters/numbers/hyphens, start with a letter, 3-64 chars"

      for bad <- ["x", "UPPER", "1lead", "-lead", "has space"] do
        assert expected_error in errors_on(changeset(slug: bad)).slug
      end
    end

    test "rejects slugs the router serves as literal /app/<segment> paths" do
      for reserved <- ["accounts", "agents", "checkout"] do
        assert "is reserved" in errors_on(changeset(slug: reserved)).slug
      end
    end

    test "installs default settings and validates the grant-lifetime cap" do
      assert %Account.Settings{
               require_mfa: false,
               require_sso: false,
               max_grant_lifetime_seconds: nil,
               pack_unseen_retention_days: nil
             } = changeset() |> apply_changes() |> Map.fetch!(:settings)

      invalid = changeset(settings: %{max_grant_lifetime_seconds: -1})

      refute invalid.valid?

      assert "must be greater than or equal to 0" in errors_on(invalid).settings.max_grant_lifetime_seconds
    end

    test "validates the pack-retention window is at least one day" do
      invalid = changeset(settings: %{pack_unseen_retention_days: 0})

      refute invalid.valid?

      assert "must be greater than 0" in errors_on(invalid).settings.pack_unseen_retention_days
    end
  end

  describe "mark_report_sent/1" do
    test "stamps last_report_sent_at" do
      account = Fixtures.Accounts.create_account()

      changeset = Account.Changeset.mark_report_sent(account)

      assert changeset.valid?
      assert %DateTime{} = Ecto.Changeset.get_change(changeset, :last_report_sent_at)
    end
  end

  defp changeset(overrides \\ %{}) do
    Account.Changeset.create(Fixtures.Accounts.account_attrs(overrides))
  end
end
