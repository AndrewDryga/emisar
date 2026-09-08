defmodule Emisar.Audit.RejectionTest do
  use Emisar.DataCase, async: true
  alias Ecto.Multi
  alias Emisar.{Audit, Fixtures, Repo}
  alias Emisar.Audit.Rejection

  test "the outer boundary records one frozen receipt after rollback and restores the error" do
    {_user, account, subject} = Fixtures.Subjects.owner_subject()

    event =
      Audit.Events.dispatch_blocked_target_unavailable(account.id, %{
        audit_subject: subject,
        action_id: "private-action",
        pack_ref: "submitted-pack",
        args: %{secret: "never retain these arguments"},
        reason: "never retain this justification"
      })

    rejection = Rejection.new(:target_contract_changed, event)
    refute inspect(rejection) =~ "private-action"
    refute inspect(rejection) =~ "never retain"

    result =
      Multi.new()
      |> Multi.run(:rejected, fn _repo, _changes ->
        assert Repo.in_transaction?()
        assert Rejection.finish({:error, rejection}) == {:error, rejection}
        {:error, rejection}
      end)
      |> Repo.commit_multi()

    assert rejected_events() == []
    finished = Rejection.finish(result)
    assert finished == {:error, :target_contract_changed}
    assert Rejection.finish(finished) == finished

    assert [recorded] = rejected_events()
    assert recorded.account_id == account.id
    assert recorded.actor_id == subject.actor.id
    assert recorded.occurred_at == Ecto.Changeset.get_field(event, :occurred_at)
    assert recorded.retain_until == Ecto.Changeset.get_field(event, :retain_until)

    assert recorded.payload == %{
             "requested_action_id" => "private-action",
             "requested_pack_ref" => "submitted-pack"
           }
  end

  test "prevalidation receipts bound submitted text and exclude foreign target facts" do
    {_user, account, subject} = Fixtures.Subjects.owner_subject()

    event =
      Audit.Events.dispatch_blocked_target_unavailable(account.id, %{
        audit_subject: subject,
        action_id: "\u202E" <> String.duplicate("x", 500),
        pack_ref: "pack\u0000ref",
        runner_id: Ecto.UUID.generate(),
        target_label: "foreign host",
        args_raw: "sensitive"
      })

    assert event.valid?
    assert Ecto.Changeset.get_field(event, :target_id) == nil
    assert Ecto.Changeset.get_field(event, :target_label) == nil

    assert Ecto.Changeset.get_field(event, :payload) == %{
             requested_action_id: String.duplicate("x", 255),
             requested_pack_ref: "packref"
           }
  end

  test "a rejected receipt insert preserves the original rejection and logs no payload" do
    {_user, account, subject} = Fixtures.Subjects.owner_subject()

    event =
      Audit.Events.dispatch_blocked_target_unavailable(account.id, %{
        audit_subject: subject,
        action_id: "private-action"
      })
      |> Ecto.Changeset.add_error(:event_type, "invalid")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert Rejection.finish({:error, Rejection.new(:target_contract_changed, event)}) ==
                 {:error, :target_contract_changed}
      end)

    assert log =~ "Could not record rejected action audit event"
    refute log =~ "private-action"
    assert rejected_events() == []
  end

  defp rejected_events do
    Audit.Event
    |> Repo.all()
    |> Enum.filter(&(&1.event_type == "dispatch_blocked_target_unavailable"))
  end
end
