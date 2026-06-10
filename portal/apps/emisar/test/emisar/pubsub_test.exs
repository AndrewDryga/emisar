defmodule Emisar.PubSubTest do
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.Audit

  # Topic names are private to the owning contexts now — the account
  # scoping guarantee is asserted through the public subscribe/broadcast
  # surface instead of string-shape checks.
  test "context topics are account-scoped: another account's broadcast never arrives" do
    account_a = account_fixture()
    account_b = account_fixture()

    :ok = Audit.subscribe_account_audit(account_a.id)

    {:ok, event_b} = Audit.log(account_b.id, "scope.test", actor_kind: "system")
    Audit.broadcast_event(event_b)
    refute_receive {:audit_event, _}, 50

    {:ok, event_a} = Audit.log(account_a.id, "scope.test", actor_kind: "system")
    Audit.broadcast_event(event_a)
    assert_receive {:audit_event, received}, 500
    assert received.id == event_a.id
  end
end
