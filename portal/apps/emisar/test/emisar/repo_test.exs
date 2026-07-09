defmodule Emisar.RepoTest do
  @moduledoc """
  The transaction-composition guard shared by `commit_multi/2` and
  `fetch_and_update/3`: an `:after_commit` side effect is illegal inside an
  already-open transaction. There the helper's transaction JOINS the outer one,
  so its "after commit" fires when the INNER call returns — before the OUTER
  commit — letting a broadcast/email escape a later outer rollback (the bug that
  let a denied/expired approval announce a run cancellation that hadn't
  committed). Callers must compose the steps into the outer Multi and hoist the
  side effect to the outer commit instead.
  """
  use Emisar.DataCase, async: true
  alias Ecto.Multi
  alias Emisar.Repo

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

  describe ":after_commit must not be used inside an open transaction" do
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
