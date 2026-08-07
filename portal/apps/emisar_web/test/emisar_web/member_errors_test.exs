defmodule EmisarWeb.MemberErrorsTest do
  @moduledoc """
  Team and SSO settings administer the same memberships through the same
  Accounts functions and each carried its own mapping of the same domain error
  atoms. They worded the same refusal differently, and for
  `:insufficient_privileges` they described different MECHANISMS — one the
  permission-subset rule the domain implements, the other a role-rank comparison
  it does not.
  """
  use ExUnit.Case, async: true
  alias EmisarWeb.MemberErrors

  test "every reason the domain can return has a written sentence" do
    generic = MemberErrors.message(:some_reason_with_no_sentence)

    for reason <- MemberErrors.reasons() do
      message = MemberErrors.message(reason)
      refute message == generic, "#{reason} falls through to the generic sentence"
      assert String.ends_with?(message, "."), "#{reason} is not a sentence: #{message}"
    end
  end

  # The no-escalation primitive is `for_role(role) ⊆ subject.permissions` — a
  # permission-subset check, with no role hierarchy. The sentence has to describe
  # that, because an operator who reads "equal to or above yours" will look for a
  # rank that does not exist.
  test "insufficient_privileges names the permission rule, not a rank" do
    message = MemberErrors.message(:insufficient_privileges)
    assert message =~ "permissions you already hold"
    refute message =~ "above yours"
  end

  test "a changeset is the invalid-input sentence, not the generic one" do
    assert MemberErrors.message(%Ecto.Changeset{}) =~ "wasn't valid"
  end

  # A domain error nobody has worded yet still has to reach the operator as
  # something actionable rather than crashing their page.
  test "an unmapped reason degrades to an actionable sentence" do
    assert MemberErrors.message(:some_future_domain_error) =~ "Refresh"
    assert MemberErrors.message({:weird, :shape}) =~ "Refresh"
  end
end
