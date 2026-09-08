defmodule Emisar.AuditIdentityOptionsTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Audit, Fixtures}

  setup do
    account = Fixtures.Accounts.create_account()
    user = Fixtures.Users.create_user()

    Fixtures.Memberships.create_membership(
      account_id: account.id,
      user_id: user.id,
      role: "owner"
    )

    subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
    %{account: account, subject: subject, user: user}
  end

  describe "list_actor_options/3" do
    test "caps pages, breaks duplicate-label ties and walks both directions", %{
      account: account,
      subject: subject
    } do
      expected =
        for _ <- 1..53 do
          id = Ecto.UUID.generate()
          event(account, id, "Same name")
          {id, "Same name"}
        end
        |> Enum.sort()

      assert {:ok, first, meta} =
               Audit.list_actor_options("user", subject, page: [limit: 999])

      assert first == Enum.take(expected, 50)
      assert meta.count == nil
      assert meta.limit == 50
      assert meta.previous_page_cursor == nil

      assert {:ok, last, last_meta} =
               Audit.list_actor_options("user", subject, page: [cursor: meta.next_page_cursor])

      assert last == Enum.drop(expected, 50)
      assert last_meta.next_page_cursor == nil

      assert {:ok, ^first, _} =
               Audit.list_actor_options("user", subject,
                 page: [cursor: last_meta.previous_page_cursor]
               )
    end

    test "search reaches beyond the first page and treats wildcard characters literally", %{
      account: account,
      subject: subject
    } do
      for i <- 1..51, do: event(account, Ecto.UUID.generate(), "A #{i}")
      id = Ecto.UUID.generate()
      event(account, id, "Zürich 100%_\\done")
      event(account, Ecto.UUID.generate(), "Zürich 100XXdone")

      assert {:ok, [{^id, "Zürich 100%_\\done"}], meta} =
               Audit.list_actor_options("user", subject, search: "  100%_\\  ")

      assert meta.next_page_cursor == nil
      assert {:ok, options, _} = Audit.list_actor_options("user", subject, search: "Zürich")
      assert length(options) == 2
    end

    test "pins a selected identity without moving either page cursor", %{
      account: account,
      subject: subject
    } do
      ids = for i <- 1..3, do: event(account, Ecto.UUID.generate(), "Person #{i}").actor_id
      selected = List.last(ids)
      assert {:ok, first, meta} = Audit.list_actor_options("user", subject, page: [limit: 1])

      assert {:ok, pinned, ^meta} =
               Audit.list_actor_options("user", subject, page: [limit: 1], ensure: selected)

      assert pinned == first ++ [{selected, "Person 3"}]

      assert {:ok, [{^selected, "Person 3"}], empty_meta} =
               Audit.list_actor_options("user", subject, search: "no match", ensure: selected)

      assert empty_meta.next_page_cursor == nil
      assert empty_meta.previous_page_cursor == nil
    end

    test "current account name wins over snapshots, including deleted users and suspended seats",
         %{account: account, subject: subject} do
      member = Fixtures.Users.create_user(full_name: "Current name")

      membership =
        Fixtures.Memberships.create_membership(account_id: account.id, user_id: member.id)

      event(account, member.id, "Old name")
      Fixtures.Users.mark_user_as_deleted(member)
      Fixtures.Memberships.suspend_membership(membership)

      assert {:ok, [{id, "Current name"}], _} = Audit.list_actor_options("user", subject)
      assert id == member.id
      assert {:ok, [], _} = Audit.list_actor_options("user", subject, search: "Old")

      Fixtures.Memberships.mark_membership_as_deleted(membership)
      assert {:ok, [{^id, "Old name"}], _} = Audit.list_actor_options("user", subject)
    end

    test "latest nonblank readable snapshot wins before search, not an older matching name", %{
      account: account,
      subject: subject
    } do
      id = Ecto.UUID.generate()
      now = DateTime.utc_now()
      event(account, id, "Old match", occurred_at: DateTime.add(now, -3))
      event(account, id, "Current snapshot", occurred_at: DateTime.add(now, -2))
      event(account, id, "   ", occurred_at: DateTime.add(now, -1))
      event(account, id, nil, occurred_at: now)

      assert {:ok, [{^id, "Current snapshot"}], _} = Audit.list_actor_options("user", subject)
      assert {:ok, [], _} = Audit.list_actor_options("user", subject, search: "Old match")
    end

    test "unknown ids stay out of ordinary choices but selected history retains an id", %{
      account: account,
      subject: subject
    } do
      id = Ecto.UUID.generate()
      event(account, id, nil)
      assert {:ok, [], _} = Audit.list_actor_options("user", subject)
      assert {:ok, [{^id, ^id}], _} = Audit.list_actor_options("user", subject, ensure: id)
      assert {:ok, [], _} = Audit.list_actor_options("user", subject, ensure: "malformed")
    end

    test "an uppercase selected UUID does not duplicate an ordinary choice", %{
      account: account,
      subject: subject
    } do
      id = Ecto.UUID.generate()
      event(account, id, "Selected")

      assert {:ok, [{^id, "Selected"}], _} =
               Audit.list_actor_options("user", subject, ensure: String.upcase(id))

      assert {:ok, [{^id, "Selected"}], _} =
               Audit.list_target_options("user", subject, ensure: String.upcase(id))
    end

    test "denies before inspecting search and rejects oversized input or an unknown kind", %{
      account: account,
      subject: subject
    } do
      denied = Fixtures.Subjects.permissionless_subject(account)
      assert {:error, :unauthorized} = Audit.list_actor_options("user", denied, search: %{})

      assert {:error, :invalid_search} =
               Audit.list_actor_options("user", subject, search: String.duplicate("é", 257))

      assert {:error, :invalid_search} =
               Audit.list_actor_options("user", subject, search: %{})

      for search <- [<<0>>, <<255>>] do
        assert {:error, :invalid_search} =
                 Audit.list_actor_options("user", subject, search: search)
      end

      assert {:error, :invalid_kind} = Audit.list_actor_options("not-a-kind", subject)

      assert {:error, :invalid_cursor} =
               Audit.list_actor_options("user", subject, page: [cursor: "bad"])
    end
  end

  describe "list_target_options/3" do
    test "projects pack, policy, grant and identity-provider labels with existing wording", %{
      account: account,
      user: user,
      subject: subject
    } do
      pack =
        Fixtures.Catalog.create_observed_pack_version(
          account_id: account.id,
          pack_id: "database",
          version: "1.2.3"
        )

      {_token, key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)

      grant =
        Fixtures.Approvals.create_grant(
          account_id: account.id,
          api_key_id: key.id,
          action_id: "database.inspect"
        )

      provider =
        Fixtures.SSO.create_identity_provider(account_id: account.id, name: "Directory")

      Fixtures.SSO.mark_provider_deleted(provider)

      account_policy =
        Fixtures.Policies.create_policy(account_id: account.id, created_by_id: user.id)

      group_policy =
        Fixtures.Policies.create_policy(
          account_id: account.id,
          created_by_id: user.id,
          scope_type: :group,
          scope_value: "database"
        )

      runner_id = Ecto.UUID.generate()

      runner_policy =
        Fixtures.Policies.create_policy(
          account_id: account.id,
          created_by_id: user.id,
          scope_type: :runner,
          scope_value: runner_id
        )

      for {kind, row, label} <- [
            {"pack_version", pack, "database@1.2.3"},
            {"approval_grant", grant, "database.inspect"},
            {"identity_provider", provider, "Directory"},
            {"policy", account_policy, "Default policy"},
            {"policy", group_policy, "Group policy · database"},
            {"policy", runner_policy, "Runner policy · #{runner_id}"}
          ] do
        receipt = event(account, row.id, "Old snapshot", target_kind: kind)
        assert {:ok, options, _} = Audit.list_target_options(kind, subject, search: label)
        assert {row.id, label} in options
        assert Audit.resolve_references([receipt], subject)[kind][row.id] == label
      end
    end

    test "the account's directory name wins over global and other-account labels", %{
      account: account,
      subject: subject
    } do
      user = Fixtures.Users.create_user(full_name: "Global name")
      local = Fixtures.Memberships.create_membership(account_id: account.id, user_id: user.id)
      foreign = Fixtures.Memberships.create_membership(user_id: user.id)
      Fixtures.Memberships.sync_display_name(local, "Local directory")
      Fixtures.Memberships.sync_display_name(foreign, "Private foreign directory")
      event(account, user.id, "Old snapshot")

      assert {:ok, [{id, "Local directory"}], _} = Audit.list_target_options("user", subject)
      assert id == user.id
      assert {:ok, [], _} = Audit.list_target_options("user", subject, search: "foreign")
      assert {:ok, [], _} = Audit.list_target_options("user", subject, search: "Global")
    end

    test "draft-test approval labels preserve the queue wording", %{
      account: account,
      user: user,
      subject: subject
    } do
      request =
        Fixtures.Approvals.create_execution_request(account, user,
          execution_kind: :draft_test,
          runbook_title: "Review plan"
        )

      event(account, request.id, nil, target_kind: "approval_request")

      assert {:ok, [{id, "Draft test · Review plan"}], _} =
               Audit.list_target_options("approval_request", subject)

      assert id == request.id
    end

    test "requires readable history even when the selected current row is local", %{
      account: account,
      subject: subject
    } do
      member = Fixtures.Users.create_user(full_name: "Quiet")
      Fixtures.Memberships.create_membership(account_id: account.id, user_id: member.id)

      assert {:ok, [{id, "Quiet"}], _} =
               Audit.list_actor_options("user", subject, ensure: member.id)

      assert id == member.id
      assert {:ok, [], _} = Audit.list_target_options("user", subject, ensure: member.id)
      event(account, member.id, nil)

      assert {:ok, [{^id, "Quiet"}], _} =
               Audit.list_target_options("user", subject, ensure: member.id)
    end

    test "historical pages, selected fallbacks and searches never cross accounts", %{
      subject: subject,
      account: account
    } do
      foreign = Fixtures.Accounts.create_account()
      id = Ecto.UUID.generate()
      event(foreign, id, "Foreign secret")

      assert {:ok, [], _} =
               Audit.list_target_options("user", subject, ensure: id, search: "secret")

      assert {:ok, [], _} = Audit.list_actor_options("user", subject, ensure: id)

      event(account, id, "Local receipt")

      assert {:ok, [{^id, "Local receipt"}], _} =
               Audit.list_target_options("user", subject, ensure: id)

      assert {:ok, [], _} = Audit.list_target_options("user", subject, search: "secret")
    end

    test "billing-only readers cannot discover operational identities or hidden newer labels", %{
      account: account
    } do
      billing =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "billing_manager")
        |> Fixtures.Subjects.membership_subject()

      id = Ecto.UUID.generate()
      hidden_id = Ecto.UUID.generate()
      now = DateTime.utc_now()

      event(account, id, "Billing label",
        event_type: "subscription.changed",
        occurred_at: DateTime.add(now, -1)
      )

      event(account, id, "Hidden latest", occurred_at: now)
      event(account, hidden_id, "Hidden person")

      for read <- [&Audit.list_actor_options/3, &Audit.list_target_options/3] do
        assert {:ok, [{^id, "Billing label"}], _} = read.("user", billing, [])
        assert {:ok, [], _} = read.("user", billing, search: "Hidden", ensure: hidden_id)
      end
    end

    test "denies a permissionless reader", %{account: account} do
      assert {:error, :unauthorized} =
               Audit.list_target_options(
                 "user",
                 Fixtures.Subjects.permissionless_subject(account)
               )
    end
  end

  defp event(account, id, label, opts \\ []) do
    {event_type, attrs} = Keyword.pop(opts, :event_type, "user.updated")

    {:ok, event} =
      Audit.log(
        account.id,
        event_type,
        Keyword.merge(
          [
            actor_kind: "user",
            actor_id: id,
            actor_label: label,
            target_kind: "user",
            target_id: id,
            target_label: label
          ],
          attrs
        )
      )

    event
  end
end
