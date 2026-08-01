defmodule Emisar.Runs.ActionRun.ChangesetTest do
  use Emisar.DataCase, async: true
  alias Emisar.Crypto
  alias Emisar.Runbooks
  alias Emisar.Runs.ActionRun

  defp base_attrs(extra) do
    Map.merge(
      %{
        account_id: Ecto.UUID.generate(),
        runner_id: Ecto.UUID.generate(),
        request_id: Crypto.run_request_id(),
        action_id: "linux.uptime",
        source: :mcp
      },
      extra
    )
  end

  describe "create/1" do
    # The action-args envelope is declared once in the runbook definition
    # schema's x-emisar-limits; the persistence changeset must enforce exactly
    # that limit or the dispatch surfaces (MCP raw span, runbook
    # materialization, pack argument bounds) drift apart.
    test "accepts args_raw at exactly the declared envelope" do
      envelope = Runbooks.Definition.limit!(:max_action_args_bytes)
      filler = String.duplicate("a", envelope - byte_size(~s({"script":""})))
      raw = Jason.encode!(%{"script" => filler})
      assert byte_size(raw) == envelope

      changeset = ActionRun.Changeset.create(base_attrs(%{args_raw: raw}))

      assert changeset.valid?
    end

    test "rejects args_raw one byte over the declared envelope" do
      envelope = Runbooks.Definition.limit!(:max_action_args_bytes)
      filler = String.duplicate("a", envelope - byte_size(~s({"script":""})) + 1)
      raw = Jason.encode!(%{"script" => filler})
      assert byte_size(raw) == envelope + 1

      changeset = ActionRun.Changeset.create(base_attrs(%{args_raw: raw}))

      assert "is too large (max #{envelope} bytes)" in errors_on(changeset).args_raw
    end
  end
end
