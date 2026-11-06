defmodule Emisar.Runbooks.NamingTest do
  use ExUnit.Case, async: true
  alias Emisar.Runbooks.Naming

  describe "resolve_slug/2" do
    test "keeps an explicit candidate unchanged" do
      assert Naming.resolve_slug("Check database fleet", "db-health") == "db-health"
    end

    test "derives from the title when no candidate was given" do
      assert Naming.resolve_slug("Check database fleet", nil) == "check-database-fleet"
      assert Naming.resolve_slug("Check database fleet", "") == "check-database-fleet"
      assert Naming.resolve_slug("Check database fleet", "   ") == "check-database-fleet"
    end

    test "bounds a derived slug to the 79 characters the slug format allows" do
      assert Naming.resolve_slug(String.duplicate("a", 100), nil) == String.duplicate("a", 79)
    end

    test "prefixes a derived slug that would not start with a letter" do
      assert Naming.resolve_slug("502 triage", nil) == "rb-502-triage"
      assert Naming.resolve_slug("2FA reset", "") == "rb-2fa-reset"

      long = Naming.resolve_slug(String.duplicate("1", 100), nil)
      assert long == "rb-" <> String.duplicate("1", 76)
    end

    test "falls back to a fixed slug when the title has no Latin letters or digits" do
      assert Naming.resolve_slug("Перезапуск", nil) == "runbook"
      assert Naming.resolve_slug("!!!", nil) == "runbook"
      assert Naming.resolve_slug(nil, nil) == "runbook"
    end

    test "returns a nonblank invalid candidate unchanged so the changeset rejects it" do
      assert Naming.resolve_slug("Check database fleet", " Not A Slug ") == " Not A Slug "
    end
  end
end
