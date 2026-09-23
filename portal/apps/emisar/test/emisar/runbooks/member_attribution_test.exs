defmodule Emisar.Runbooks.MemberAttributionTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Fixtures, Repo, Runbooks}

  test "the database rejects a runbook author from another workspace" do
    account = Fixtures.Accounts.create_account()
    foreign = Fixtures.Memberships.create_membership()

    changeset =
      Runbooks.Runbook.Changeset.create(account.id, foreign.id, Fixtures.Runbooks.runbook_attrs())

    assert {:error, changeset} = Repo.insert(changeset)
    assert "does not exist" in errors_on(changeset).created_by_membership_id
    refute Repo.one(Runbooks.Runbook)
  end

  test "the database rejects a release publisher from another workspace" do
    runbook = Fixtures.Runbooks.create_runbook()
    foreign = Fixtures.Memberships.create_membership()

    changeset =
      Runbooks.Release.Changeset.create(%{
        account_id: runbook.account_id,
        runbook_id: runbook.id,
        version: 1,
        title: runbook.title,
        definition: runbook.draft_definition,
        definition_sha256: Runbooks.definition_digest(runbook.draft_definition),
        published_by_membership_id: foreign.id
      })

    assert {:error, changeset} = Repo.insert(changeset)
    assert "does not exist" in errors_on(changeset).published_by_membership_id
    refute Repo.one(Runbooks.Release)
  end

  test "hard deletion of a Member retains the runbook, release and their account" do
    member = Fixtures.Memberships.create_membership()

    runbook =
      Fixtures.Runbooks.create_runbook(
        account_id: member.account_id,
        created_by_membership_id: member.id
      )
      |> Fixtures.Runbooks.publish_runbook()

    release = Repo.one!(Runbooks.Release)
    Repo.delete!(member)

    retained = Repo.reload!(runbook)
    assert retained.account_id == member.account_id
    refute retained.created_by_membership_id
    assert retained.live_version == runbook.live_version

    retained_release = Repo.reload!(release)
    assert retained_release.account_id == member.account_id
    assert retained_release.runbook_id == runbook.id
    refute retained_release.published_by_membership_id
    assert retained_release.definition == release.definition
  end
end
