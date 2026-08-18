defmodule Emisar.RepoTest do
  @moduledoc """
  The transaction-composition guards shared by `commit_multi/2` and
  `fetch_and_update/3`: a side effect that must wait for a commit is illegal
  inside an already-open transaction. There the helper's transaction JOINS the
  outer one, so anything it fires when the INNER call returns happens before the
  OUTER commit — letting a broadcast/email escape a later outer rollback (the bug
  that let a denied/expired approval announce a run cancellation that hadn't
  committed, and the one that let a rolled-back `runner.enabled` reach the audit
  trail's live subscribers). Two options carry such an effect: `:after_commit`
  and `:audit`, whose row is transactional but whose broadcast is not. Callers
  must compose the steps into the outer Multi and hoist the side effect — or the
  audit row itself — to the outer commit instead.
  """
  use Emisar.DataCase, async: true
  alias Ecto.Multi
  alias Emisar.{Audit, Fixtures, Repo, Users}

  describe "valid_uuid?/1" do
    test "accepts canonical UUID text and rejects malformed or raw values" do
      assert Repo.valid_uuid?(Ecto.UUID.generate())
      assert Repo.valid_uuid?("A0B1C2D3-E4F5-6789-ABCD-EF0123456789")
      refute Repo.valid_uuid?("zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz")
      refute Repo.valid_uuid?("12345678-1234-1234-1234-1234567890")
      refute Repo.valid_uuid?(<<0::128>>)
      refute Repo.valid_uuid?(nil)
    end
  end

  describe "commit-dependent side effects must not be used inside an open transaction" do
    test "commit_multi/2 raises when :after_commit is given inside an open transaction" do
      multi = Multi.run(Multi.new(), :noop, fn _repo, _changes -> {:ok, :done} end)

      assert_raise ArgumentError, ~r/fires before the outer commit/, fn ->
        Repo.transaction(fn -> Repo.commit_multi(multi, after_commit: fn _ -> :ok end) end)
      end
    end

    test "fetch_and_update/3 raises when :after_commit is given inside an open transaction" do
      # The guard runs before any query work, so a nil queryable never executes.
      assert_raise ArgumentError, ~r/fires before/, fn ->
        Repo.transaction(fn ->
          Repo.fetch_and_update(nil, nil, with: fn _ -> :ok end, after_commit: fn _ -> :ok end)
        end)
      end
    end

    test "a nested :audit does not announce an event the outer transaction rolls back" do
      # Composing an audited fetch_and_update into an outer Multi stays legal: the
      # audit row commits or rolls back with the mutation. Its BROADCAST used to
      # fire as soon as the nested call returned, so subscribers were told about a
      # `user.renamed_via_scim` that the outer rollback then erased — an audit
      # trail announcing something that never happened.
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user(full_name: "Original Name")
      Fixtures.Memberships.create_membership(account_id: account.id, user_id: user.id)
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)

      :ok = Audit.subscribe_account_audit(account.id)

      multi =
        Multi.new()
        |> Multi.run(:rename, fn _repo, _changes ->
          Users.sync_user_full_name(user.id, "Directory Name",
            audit: &Audit.Events.user_renamed_via_scim(&1, provider)
          )
        end)
        |> Multi.run(:fail, fn _repo, _changes -> {:error, :forced_rollback} end)

      assert Repo.commit_multi(multi) == {:error, :forced_rollback}

      # The write rolled back...
      assert {:ok, %{full_name: "Original Name"}} = Users.fetch_user_by_id(user.id)
      # ...and nothing was announced about it.
      refute_receive {:audit_event, _event}, 200
    end

    test "commit_multi/2 fires :after_commit at the top level (no open transaction)" do
      multi = Multi.run(Multi.new(), :noop, fn _repo, _changes -> {:ok, :done} end)
      parent = self()

      after_commit = fn _changes ->
        send(parent, :fired)
        :ok
      end

      assert {:ok, %{noop: :done}} = Repo.commit_multi(multi, after_commit: after_commit)

      assert_receive :fired, 500
    end
  end
end
