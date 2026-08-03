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
      assert Naming.resolve_slug(nil, nil) == ""
    end

    test "bounds a derived slug to the 79 characters the slug format allows" do
      assert Naming.resolve_slug(String.duplicate("a", 100), nil) == String.duplicate("a", 79)
    end

    test "returns a nonblank invalid candidate unchanged so the changeset rejects it" do
      assert Naming.resolve_slug("Check database fleet", " Not A Slug ") == " Not A Slug "
    end
  end
end
