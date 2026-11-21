defmodule Emisar.AuditExportConcurrencyTest do
  use Emisar.ConcurrencyCase, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Emisar.{Accounts, Audit, Fixtures, Repo}

  @moduletag timeout: 60_000

  test "an open audit writer holds the SIEM page back until it commits, then delivers in order" do
    Sandbox.unboxed_run(Repo, fn ->
      account = Fixtures.Accounts.create_account()
      Fixtures.Accounts.create_subscription(account, "team")

      subject =
        Fixtures.Subjects.subject_for(
          Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")
        )

      parent = self()

      writer =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            {:ok, event} = Audit.log(account.id, "user.signed_in", actor_kind: "user")
            send(parent, {:written, event})

            receive do
              :commit -> event
            end
          end)
        end)

      try do
        assert_receive {:written, late}, 10_000

        # A later transaction stamps and commits while the first is still open.
        {:ok, early} = Audit.log(account.id, "user.signed_in", actor_kind: "user")

        # Nothing at or above the open writer's transaction is served, so no
        # cursor can be issued past the row it has not committed yet.
        assert Audit.list_for_export(subject, event_types: ["user.signed_in"]) == {:ok, []}

        send(writer.pid, :commit)
        assert {:ok, %Audit.Event{id: late_id}} = Task.await(writer, 10_000)
        assert late_id == late.id

        assert await_export(subject, 2) |> Enum.map(& &1.id) == [late.id, early.id]
      after
        stop_tasks([writer])
        Repo.delete_all(from(row in Accounts.Account, where: row.id == ^account.id))
      end
    end)
  end

  # The horizon is cluster-wide: another suite's open transaction can hold it
  # back briefly, so wait for it to pass rather than asserting on one poll.
  defp await_export(subject, count, deadline \\ System.monotonic_time(:millisecond) + 20_000) do
    {:ok, events} = Audit.list_for_export(subject, event_types: ["user.signed_in"])

    cond do
      length(events) >= count -> events
      System.monotonic_time(:millisecond) > deadline -> flunk("export never passed the horizon")
      true -> await_export(subject, count, deadline)
    end
  end
end
