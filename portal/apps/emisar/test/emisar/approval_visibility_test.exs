defmodule Emisar.ApprovalVisibilityTest do
  use Emisar.DataCase, async: true
  alias Emisar.Accounts.RunnerAccess
  alias Emisar.{Approvals, Fixtures, Repo, Runbooks}

  setup do
    membership = Fixtures.Memberships.create_membership(role: "admin")
    subject = Fixtures.Subjects.membership_subject(membership)
    %{membership: membership, subject: subject, account: subject.account}
  end

  describe "pending_request_filters/1" do
    test "defaults deciders to their queue and read-only roles to All requests", %{
      subject: subject
    } do
      assert [%{name: :view, default: "needs_decision", prompt: "All requests"}] =
               Approvals.pending_request_filters(subject)

      viewer =
        Fixtures.Memberships.create_membership(role: "viewer")
        |> Fixtures.Subjects.membership_subject()

      assert [%{default: nil, prompt: "All requests"}] = Approvals.pending_request_filters(viewer)

      assert [%{default: nil}] =
               Approvals.pending_request_filters(%{subject | permissions: MapSet.new()})
    end
  end

  describe "list_pending_approval_requests/2" do
    test "eligibility applies before FIFO pagination and matches the badge", %{subject: subject} do
      self_request =
        request(subject, requested_by_id: subject.actor.id, allow_self_approval: false)

      expired = request(subject, expires_at: DateTime.add(DateTime.utc_now(), -1))
      voted = request(subject, min_approvals: 2)

      Approvals.Decision.Changeset.create(subject.account.id, voted.id, subject.actor.id, %{
        decision: :approve,
        decided_at: DateTime.utc_now()
      })
      |> Repo.insert!()

      eligible = for _ <- 1..3, do: request(subject)
      assert Approvals.count_pending_approval_requests(subject) == 3

      assert {:ok, [first, second], %{count: 3, next_page_cursor: cursor}} =
               Approvals.list_pending_approval_requests(subject,
                 view: :needs_decision,
                 page: [limit: 2]
               )

      assert {:ok, [third], %{next_page_cursor: nil}} =
               Approvals.list_pending_approval_requests(subject,
                 view: :needs_decision,
                 page: [limit: 2, cursor: cursor]
               )

      assert Enum.map([first, second, third], & &1.id) == Enum.map(eligible, & &1.id)
      assert {:ok, all, %{count: 6}} = Approvals.list_pending_approval_requests(subject)

      assert MapSet.subset?(
               MapSet.new([self_request.id, expired.id, voted.id]),
               MapSet.new(all, & &1.id)
             )
    end

    test "nil deadlines and permitted self approval remain actionable", %{subject: subject} do
      own =
        request(subject,
          requested_by_id: subject.actor.id,
          allow_self_approval: true,
          expires_at: nil
        )

      assert {:ok, [listed], _} =
               Approvals.list_pending_approval_requests(subject, view: :needs_decision)

      assert listed.id == own.id
      assert Approvals.count_pending_approval_requests(subject) == 1
    end

    test "a stale role can read shared requests but cannot claim an actionable queue", %{
      membership: membership,
      subject: subject
    } do
      request = request(subject)
      Fixtures.Memberships.force_role(membership, "viewer")
      assert {:ok, [listed], _} = Approvals.list_pending_approval_requests(subject)
      assert listed.id == request.id

      assert {:ok, [], %{count: 0}} =
               Approvals.list_pending_approval_requests(subject, view: :needs_decision)

      assert Approvals.count_pending_approval_requests(subject) == 0

      assert {:ok, %{can_decide?: false, can_override?: false, target_authorized?: false}} =
               Approvals.fetch_approval_review(request.id, subject)
    end

    test "every frozen execution target must remain valid and covered", %{
      subject: subject,
      membership: membership,
      account: account
    } do
      request = Fixtures.Approvals.create_execution_request(account, subject.actor)

      items =
        Runbooks.ExecutionItem.Query.by_execution_id(request.runbook_execution_id) |> Repo.all()

      [first, second] = items

      {:ok, access} =
        RunnerAccess.new(:restricted, [], Enum.map(items, & &1.runner_id), :restricted, [
          "postgres"
        ])

      Fixtures.Memberships.force_runner_access(membership, access)
      assert Approvals.count_pending_approval_requests(subject) == 1

      second |> Ecto.Changeset.change(pack_ref: "invalid-pack-reference") |> Repo.update!()
      assert Approvals.count_pending_approval_requests(subject) == 0

      assert {:ok, %{target_authorized?: false}} =
               Approvals.fetch_approval_review(request.id, subject)

      assert Approvals.deny_request(request, subject, "corrupt target") == {:error, :not_found}

      Repo.get!(Emisar.Runners.Runner, first.runner_id) |> Fixtures.Runners.mark_deleted()
      second |> Ecto.Changeset.change(pack_ref: first.pack_ref) |> Repo.update!()
      assert Approvals.count_pending_approval_requests(subject) == 0
      assert {:ok, [_], _} = Approvals.list_pending_approval_requests(subject)
      assert Repo.reload!(request).status == :pending
    end
  end

  describe "fetch_approval_request_by_id/3" do
    for invalidation <- [:suspended, :deleted_user, :disabled_account] do
      test "shared read entrypoints reject #{invalidation} identity", %{
        membership: membership,
        subject: subject
      } do
        request = request(subject)
        invalidate(membership, subject, unquote(invalidation))

        for read <- [
              fn -> Approvals.list_pending_approval_requests(subject) end,
              fn -> Approvals.list_approval_requests_for_account(subject) end,
              fn -> Approvals.fetch_approval_request_by_id(request.id, subject) end,
              fn -> Approvals.fetch_approval_review(request.id, subject) end,
              fn -> Approvals.risk_by_request_ids([request.id], subject) end,
              fn -> Approvals.list_decisions_for_request(request, subject) end,
              fn -> Approvals.approved_count_for_request(request, subject) end,
              fn -> Approvals.list_grants_for_account(subject) end,
              fn -> Approvals.grant_management_by_ids([], subject) end
            ] do
          assert read.() == {:error, :unauthorized}
        end

        assert Approvals.count_pending_approval_requests(subject) == 0
      end
    end
  end

  describe "grant_management_by_ids/2" do
    test "global hint sees denied grants beyond the rendered page and ignores expired/revoked grants",
         %{membership: membership, subject: subject} do
      runner = Fixtures.Runners.create_runner(account_id: subject.account.id)

      {_, key} =
        Fixtures.ApiKeys.create_api_key(
          account_id: subject.account.id,
          created_by_id: subject.actor.id
        )

      create =
        &Fixtures.Approvals.create_grant(
          Keyword.merge(
            [
              account_id: subject.account.id,
              api_key_id: key.id,
              granted_by_id: subject.actor.id,
              runner_id: runner.id
            ],
            &1
          )
        )

      grants = for _ <- 1..11, do: create.([])
      denied = create.(runner_id: nil)
      {:ok, access} = RunnerAccess.new(:restricted, [], [runner.id])
      Fixtures.Memberships.force_runner_access(membership, access)
      page_ids = grants |> Enum.take(10) |> Enum.map(& &1.id)

      assert {:ok, %{grants: hints, all_authorized?: false}} =
               Approvals.grant_management_by_ids(page_ids, subject)

      assert map_size(hints) == 10
      assert Enum.all?(hints, fn {_id, allowed?} -> allowed? end)

      denied
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1))
      |> Repo.update!()

      assert {:ok, %{all_authorized?: true}} =
               Approvals.grant_management_by_ids(page_ids, subject)

      revoked = create.(runner_id: nil)
      revoked |> Ecto.Changeset.change(revoked_at: DateTime.utc_now()) |> Repo.update!()

      assert {:ok, %{all_authorized?: true}} =
               Approvals.grant_management_by_ids(page_ids, subject)
    end

    test "canonical packs and existing same-account runners are required even with all access", %{
      subject: subject
    } do
      {_, key} =
        Fixtures.ApiKeys.create_api_key(
          account_id: subject.account.id,
          created_by_id: subject.actor.id
        )

      runner = Fixtures.Runners.create_runner(account_id: subject.account.id)
      foreign = Fixtures.Runners.create_runner()

      grants =
        for {runner_id, pack_ref} <- [
              {runner.id, "malformed"},
              {foreign.id, pack_ref()},
              {runner.id, pack_ref()},
              {nil, pack_ref()}
            ] do
          Fixtures.Approvals.create_grant(
            account_id: subject.account.id,
            api_key_id: key.id,
            granted_by_id: subject.actor.id,
            runner_id: runner_id,
            pack_ref: pack_ref
          )
        end

      Fixtures.Runners.mark_deleted(runner)
      [malformed, foreign, deleted, wildcard] = grants
      ids = Enum.map(grants, & &1.id)

      assert {:ok, %{grants: hints, all_authorized?: false}} =
               Approvals.grant_management_by_ids(ids, subject)

      assert hints == %{
               malformed.id => false,
               foreign.id => false,
               deleted.id => false,
               wildcard.id => true
             }

      {_user, _account, other} = Fixtures.Subjects.owner_subject()
      assert {:ok, %{grants: foreign_hints}} = Approvals.grant_management_by_ids(ids, other)
      refute Enum.any?(foreign_hints, fn {_id, allowed?} -> allowed? end)
    end
  end

  defp request(subject, attrs \\ []) do
    Fixtures.Approvals.create_request(account_id: subject.account.id)
    |> Ecto.Changeset.change(attrs)
    |> Repo.update!()
  end

  defp pack_ref, do: "postgres@1.0.0/sha256:" <> String.duplicate("a", 64)

  defp invalidate(membership, _subject, :suspended),
    do: Fixtures.Memberships.suspend_membership(membership)

  defp invalidate(_membership, subject, :deleted_user),
    do: Fixtures.Users.mark_user_as_deleted(subject.actor)

  defp invalidate(_membership, subject, :disabled_account),
    do: Fixtures.Accounts.disable_account(subject.account)
end
