defmodule Emisar.RunbooksAuthoringAccessTest do
  use Emisar.DataCase, async: true
  alias Emisar.Accounts.RunnerAccess
  alias Emisar.{Fixtures, Runbooks, Runners}

  describe "definition_authoring_access/2" do
    setup do
      membership = Fixtures.Memberships.create_membership(role: "operator")
      %{membership: membership, subject: Fixtures.Subjects.membership_subject(membership)}
    end

    test "checks grants independently of connectivity, trust and strict completeness", %{
      membership: membership,
      subject: subject
    } do
      Fixtures.Runners.create_runner(
        account_id: subject.account.id,
        group: "default",
        connected?: false
      )

      {:ok, access} =
        RunnerAccess.new(:restricted, ["default", "future"], [], :restricted, ["linux-core"])

      Fixtures.Memberships.force_runner_access(membership, access)
      definition = Fixtures.Runbooks.default_definition()
      assert Runbooks.definition_authoring_access(definition, subject) == {:ok, :authorized}

      future =
        put_in(definition, ["stages", Access.at(0), "steps", Access.at(0), "targets", "refs"], [
          "group:future"
        ])

      assert Runbooks.definition_authoring_access(future, subject) == {:ok, :authorized}

      Fixtures.Memberships.force_runner_access(membership, RunnerAccess.none())
      incomplete = Map.put(definition, "stages", [])
      assert Runbooks.definition_authoring_access(incomplete, subject) == {:ok, :authorized}
      assert {:error, _issues} = Runbooks.validate_definition(incomplete)
    end

    test "denies current role loss and separately enforces both action dimensions", %{
      membership: membership,
      subject: subject
    } do
      definition = Fixtures.Runbooks.default_definition()
      {:ok, access} = RunnerAccess.new(:restricted, ["other"], [], :all)
      Fixtures.Memberships.force_runner_access(membership, access)

      assert Runbooks.definition_authoring_access(definition, subject) ==
               {:error, :target_out_of_scope}

      {:ok, access} = RunnerAccess.new(:all, [], [], :restricted, [])
      Fixtures.Memberships.force_runner_access(membership, access)

      assert Runbooks.definition_authoring_access(definition, subject) ==
               {:error, :pack_out_of_scope}

      Fixtures.Memberships.force_role(membership, "viewer")

      assert Runbooks.definition_authoring_access(Map.put(definition, "stages", []), subject) ==
               {:error, :unauthorized}
    end

    test "a grant to an account runner does not permit authoring against a foreign runner", %{
      membership: membership,
      subject: subject
    } do
      foreign = Fixtures.Runners.create_runner(connected?: false)
      own = Fixtures.Runners.create_runner(account_id: subject.account.id, connected?: false)
      {:ok, ref} = Runners.public_ref(foreign)
      {:ok, access} = RunnerAccess.new(:restricted, [], [own.id], :all)
      Fixtures.Memberships.force_runner_access(membership, access)

      definition =
        put_in(
          Fixtures.Runbooks.default_definition(),
          ["stages", Access.at(0), "steps", Access.at(0), "targets", "refs"],
          ["runner:" <> ref]
        )

      assert Runbooks.definition_authoring_access(definition, subject) ==
               {:error, :target_out_of_scope}
    end
  end
end
