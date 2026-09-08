defmodule EmisarWeb.RoleCopyTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.RoleCopy

  describe "change_title/2" do
    test "asks the escalation question per named role" do
      assert RoleCopy.change_title("Dana", "owner") == "Make Dana an owner?"
      assert RoleCopy.change_title("Dana", "admin") == "Make Dana an admin?"
      assert RoleCopy.change_title("Dana", "billing_manager") == "Make Dana a billing manager?"
      assert RoleCopy.change_title("Dana", "operator") == "Make Dana an operator?"
    end

    test "falls back to the role label for any other role" do
      assert RoleCopy.change_title("Dana", "viewer") ==
               "Change Dana to #{Emisar.Auth.role_label("viewer")}?"
    end
  end

  describe "change_body/1" do
    test "a privileged role spells out the power granted" do
      assert RoleCopy.change_body("owner") =~ "access all runners and packs"

      assert RoleCopy.change_body("owner") =~
               "They can delete the account and remove or demote you."

      assert RoleCopy.change_body("admin") =~ "except adding or removing owners"
      assert RoleCopy.change_body("operator") =~ "Operators can run actions"
    end

    test "any other role states its own contract from the shared description" do
      for role <- ["billing_manager", "operator", "viewer"] do
        assert RoleCopy.change_body(role) == Emisar.Auth.role_description(role)
      end
    end
  end

  describe "access_hint/1" do
    test "offers the member action separately for admins and operators only" do
      for role <- ["admin", "operator"] do
        assert RoleCopy.access_hint(role) =~ "Actions → Edit access"
        refute RoleCopy.change_body(role) =~ "Actions → Edit access"
      end

      for role <- ["owner", "billing_manager", "viewer", "unknown"] do
        assert RoleCopy.access_hint(role) == nil
      end
    end
  end
end
