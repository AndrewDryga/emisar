defmodule Emisar.AuditIdentityHistoryTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Audit, Fixtures}

  setup do
    account = Fixtures.Accounts.create_account()
    membership = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")
    subject = Fixtures.Subjects.membership_subject(membership)
    %{account: account, subject: subject}
  end

  test "actor and target history keep their own identities and labels", %{
    account: account,
    subject: subject
  } do
    actor_id = Ecto.UUID.generate()
    target_id = Ecto.UUID.generate()

    event(account, actor_id, "Actor snapshot",
      target_id: target_id,
      target_label: "Target snapshot"
    )

    assert {:ok, [{^actor_id, "Actor snapshot"}], _} = Audit.list_actor_options("user", subject)

    assert {:ok, [{^target_id, "Target snapshot"}], _} =
             Audit.list_target_options("user", subject)

    assert {:ok, [], _} = Audit.list_actor_options("user", subject, search: "Target")
    assert {:ok, [], _} = Audit.list_target_options("user", subject, search: "Actor")
  end

  test "both sides choose the latest nonblank snapshot and break timestamp ties before search", %{
    account: account,
    subject: subject
  } do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now()
    event(account, id, "Old matching label", occurred_at: DateTime.add(now, -3))
    first = event(account, id, "First tied label", occurred_at: DateTime.add(now, -2))
    second = event(account, id, "Second tied label", occurred_at: DateTime.add(now, -2))
    event(account, id, "   ", occurred_at: DateTime.add(now, -1))
    event(account, id, nil, occurred_at: now)
    expected = Enum.max_by([first, second], & &1.id).actor_label

    for read <- [&Audit.list_actor_options/3, &Audit.list_target_options/3] do
      assert {:ok, [{^id, ^expected}], _} = read.("user", subject, [])
      assert {:ok, [], _} = read.("user", subject, search: "Old matching")
    end
  end

  test "current labels retain evidence whose stored snapshots are blank", %{
    account: account,
    subject: subject
  } do
    member = Fixtures.Users.create_user(full_name: "Current directory member")
    Fixtures.Memberships.create_membership(account_id: account.id, user_id: member.id)
    event(account, member.id, nil)
    event(account, member.id, "   ")
    expected = [{member.id, "Current directory member"}]

    for read <- [&Audit.list_actor_options/3, &Audit.list_target_options/3] do
      assert {:ok, ^expected, _} = read.("user", subject, search: "directory")
    end
  end

  test "billing current-label evidence includes blank readable events but excludes hidden events",
       %{
         account: account
       } do
    billing =
      Fixtures.Memberships.create_membership(account_id: account.id, role: "billing_manager")
      |> Fixtures.Subjects.membership_subject()

    visible_member = Fixtures.Users.create_user(full_name: "Visible member")
    hidden_member = Fixtures.Users.create_user(full_name: "Hidden member")

    for member <- [visible_member, hidden_member] do
      Fixtures.Memberships.create_membership(account_id: account.id, user_id: member.id)
    end

    event(account, visible_member.id, nil, event_type: "subscription.changed")
    event(account, hidden_member.id, "Hidden snapshot")
    expected = [{visible_member.id, "Visible member"}]

    for read <- [&Audit.list_actor_options/3, &Audit.list_target_options/3] do
      assert {:ok, ^expected, _} = read.("user", billing, [])
      assert {:ok, [], _} = read.("user", billing, search: "Hidden")
    end
  end

  test "latest historical lookup retains account and billing scope on both sides", %{
    account: account
  } do
    billing =
      Fixtures.Memberships.create_membership(account_id: account.id, role: "billing_manager")
      |> Fixtures.Subjects.membership_subject()

    foreign_account = Fixtures.Accounts.create_account()
    id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    event(account, id, "Readable snapshot",
      event_type: "subscription.changed",
      occurred_at: DateTime.add(now, -3)
    )

    event(account, id, "   ",
      event_type: "subscription.changed",
      occurred_at: DateTime.add(now, -2)
    )

    event(account, id, "Hidden operational snapshot", occurred_at: DateTime.add(now, -1))
    event(foreign_account, id, "Foreign snapshot", event_type: "subscription.changed")

    for read <- [&Audit.list_actor_options/3, &Audit.list_target_options/3] do
      assert {:ok, [{^id, "Readable snapshot"}], _} = read.("user", billing, [])

      assert {:ok, [{^id, "Readable snapshot"}], _} =
               read.("user", billing, search: "no match", ensure: id)

      for search <- ["Hidden", "Foreign"] do
        assert {:ok, [], _} = read.("user", billing, search: search)
      end
    end
  end

  test "unnamed histories remain selected-only and cannot supply another side's fallback", %{
    account: account,
    subject: subject
  } do
    actor_id = Ecto.UUID.generate()
    target_id = Ecto.UUID.generate()
    event(account, actor_id, nil, target_id: target_id)

    assert {:ok, [], _} = Audit.list_actor_options("user", subject)
    assert {:ok, [], _} = Audit.list_target_options("user", subject)

    assert {:ok, [{^actor_id, ^actor_id}], _} =
             Audit.list_actor_options("user", subject, ensure: actor_id)

    assert {:ok, [{^target_id, ^target_id}], _} =
             Audit.list_target_options("user", subject, ensure: target_id)

    assert {:ok, [], _} = Audit.list_actor_options("user", subject, ensure: target_id)
    assert {:ok, [], _} = Audit.list_target_options("user", subject, ensure: actor_id)
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
