defmodule Emisar.Mailers.ApprovalThreadingTest do
  use Emisar.DataCase, async: true
  alias Emisar.Fixtures
  alias Emisar.Mailers.UserNotifier
  alias Emisar.Runs

  test "nearby UUIDv7 action approvals have separate subjects and reply chains" do
    membership = Fixtures.Memberships.create_membership(role: "owner")
    subject = Fixtures.Subjects.membership_subject(membership)

    persisted =
      Fixtures.Runs.create_run(account_id: subject.account.id, action_id: "linux.uptime")

    {:ok, run} = Runs.fetch_run_by_id(persisted.id, subject)

    first = %{
      id: "019ec7d0-1000-7000-8000-000000000001",
      account: subject.account,
      context: %{"action_id" => run.action_id}
    }

    second = %{first | id: "019ec7d0-1001-7000-8000-000000000002"}

    UserNotifier.deliver_approval_request(subject, first, run)
    assert_receive {:email, first_email}
    UserNotifier.deliver_approval_request(subject, second, run)
    assert_receive {:email, second_email}

    refute first_email.subject == second_email.subject
    assert first_email.subject =~ first.id
    assert second_email.subject =~ second.id
    refute first_email.headers["Message-ID"] == second_email.headers["Message-ID"]

    UserNotifier.deliver_approval_event(subject, first, %{kind: :approved, approved_count: 1})
    assert_receive {:email, update}

    assert update.subject == first_email.subject
    assert update.headers["In-Reply-To"] == first_email.headers["Message-ID"]
    assert update.headers["References"] == first_email.headers["Message-ID"]
    refute update.headers["Message-ID"] == first_email.headers["Message-ID"]
    refute update.headers["References"] == second_email.headers["Message-ID"]
  end

  test "long runbook subjects retain the full request identity for every delivery path" do
    membership = Fixtures.Memberships.create_membership(role: "owner")
    subject = Fixtures.Subjects.membership_subject(membership)

    request = %{
      id: "019ec7d0-1000-7000-8000-000000000001",
      account: %{subject.account | name: String.duplicate("A", 80)},
      status: :approved,
      context: %{"runbook" => %{"title" => String.duplicate("Maintenance ", 30)}}
    }

    UserNotifier.deliver_runbook_execution_approval_request(subject, request)
    assert_receive {:email, initial}
    request = %{request | account: %{request.account | name: "Renamed account"}}
    UserNotifier.deliver_approval_event(subject, request, %{kind: :approved, approved_count: 1})
    assert_receive {:email, update}
    UserNotifier.deliver_approval_decision(subject.actor, request, 1)
    assert_receive {:email, decision}

    assert String.length(initial.subject) <= 180
    assert String.ends_with?(initial.subject, request.id)
    assert update.subject == initial.subject
    assert decision.subject == initial.subject
    assert decision.headers["In-Reply-To"] == initial.headers["Message-ID"]
    assert decision.headers["References"] == initial.headers["Message-ID"]

    other_request = %{request | id: "019ec7d0-1001-7000-8000-000000000002"}
    UserNotifier.deliver_approval_decision(subject.actor, other_request, 1)
    assert_receive {:email, other_decision}

    assert String.ends_with?(other_decision.subject, other_request.id)
    refute other_decision.subject == decision.subject
    refute other_decision.headers["References"] == decision.headers["References"]
    refute other_decision.headers["Message-ID"] == decision.headers["Message-ID"]
  end

  test "every requester outcome shares its draft approval subject and recipient root" do
    membership = Fixtures.Memberships.create_membership(role: "owner")
    subject = Fixtures.Subjects.membership_subject(membership)

    request = %{
      id: Ecto.UUID.generate(),
      account: subject.account,
      status: :pending,
      context: %{
        "execution_kind" => "draft_test",
        "runbook" => %{"title" => "Database maintenance"}
      }
    }

    UserNotifier.deliver_runbook_execution_approval_request(subject, request)
    assert_receive {:email, initial}

    for {status, event_kind} <- [
          {:approved, nil},
          {:denied, nil},
          {:expired, nil},
          {:cancelled, nil},
          {:approved, :overridden}
        ] do
      UserNotifier.deliver_approval_decision(
        subject.actor,
        %{request | status: status},
        1,
        event_kind
      )

      assert_receive {:email, decision}

      assert decision.subject == initial.subject
      assert decision.headers["In-Reply-To"] == initial.headers["Message-ID"]
      assert decision.headers["References"] == initial.headers["Message-ID"]
      assert decision.headers["X-PM-KeepID"] == "true"
      refute decision.headers["Message-ID"] == initial.headers["Message-ID"]
    end
  end

  test "each recipient has distinct message ids within the same approval" do
    first_membership = Fixtures.Memberships.create_membership(role: "owner")
    first_subject = Fixtures.Subjects.membership_subject(first_membership)

    second_membership =
      Fixtures.Memberships.create_membership(account_id: first_subject.account.id, role: "admin")

    second_subject = Fixtures.Subjects.membership_subject(second_membership)

    request = %{
      id: Ecto.UUID.generate(),
      account: first_subject.account,
      status: :approved,
      context: %{"action_id" => "linux.uptime"}
    }

    UserNotifier.deliver_approval_decision(first_subject.actor, request, 1)
    assert_receive {:email, first}
    UserNotifier.deliver_approval_decision(second_subject.actor, request, 1)
    assert_receive {:email, second}

    assert first.subject == second.subject
    assert is_binary(first.headers["Message-ID"])
    assert is_binary(first.headers["References"])
    refute first.headers["Message-ID"] == second.headers["Message-ID"]
    refute first.headers["References"] == second.headers["References"]
  end
end
