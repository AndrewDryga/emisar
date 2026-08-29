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
      assert RoleCopy.change_body("owner") =~ "can remove or demote you"
      assert RoleCopy.change_body("admin") =~ "except adding or removing owners"
      assert RoleCopy.change_body("operator") =~ "dispatch runs"
    end

    test "any other role states its own contract from the shared description" do
      assert RoleCopy.change_body("viewer") == Emisar.Auth.role_description("viewer")
    end
  end
end
