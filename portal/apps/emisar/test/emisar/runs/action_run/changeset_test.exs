defmodule Emisar.Runs.ActionRun.ChangesetTest do
  use Emisar.DataCase, async: true
  alias Emisar.Crypto
  alias Emisar.Runbooks
  alias Emisar.Runs.ActionRun

  @rlo <<0x202E::utf8>>
  @null <<0>>

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

    # The reason is what a human reads before approving a high-risk action, and
    # the model composes it from runner output the product treats as hostile. A
    # bidi override reverses the rendered text on the approval surface and in
    # the approver's email, which strips C0/C1 but not \p{Cf}.
    test "rejects a justification carrying control or formatting characters" do
      changeset = ActionRun.Changeset.create(base_attrs(%{reason: "restart" <> @rlo <> "nginx"}))

      assert "must not contain control or formatting characters" in errors_on(changeset).reason
    end

    test "rejects evidence and expected carrying them too" do
      attrs = base_attrs(%{evidence: "saw" <> @null, expected: "clean" <> @rlo <> "exit"})
      changeset = ActionRun.Changeset.create(attrs)

      errors = errors_on(changeset)
      assert "must not contain control or formatting characters" in errors.evidence
      assert "must not contain control or formatting characters" in errors.expected
    end

    test "a multi-line justification stays valid" do
      changeset =
        ActionRun.Changeset.create(base_attrs(%{reason: "disk full\nfreeing /var/log\tnow"}))

      assert changeset.valid?
    end
  end

  describe "transition/3" do
    # A terminal result must stay recordable — rejecting it would leave the run
    # unacked and the runner's dedup ring replaying it forever — so the runner's
    # text is stripped instead. `executed_command` reaches the console panel and
    # the CSV/NDJSON audit export.
    test "strips control and formatting characters from the runner's result text" do
      changeset =
        ActionRun.Changeset.transition(%ActionRun{}, :failed, %{
          executed_command: "systemctl" <> @rlo <> " restart nginx",
          error_message: "boom" <> @null,
          reason_text: "exit" <> @rlo <> " 1"
        })

      assert get_change(changeset, :executed_command) == "systemctl restart nginx"
      assert get_change(changeset, :error_message) == "boom"
      assert get_change(changeset, :reason_text) == "exit 1"
    end

    # 48 shipped actions render a multi-line shell program, so the recorded
    # command has to keep its line breaks to still describe what ran.
    test "keeps the line breaks of a multi-line executed command" do
      program = "set -e\ngrep ERROR /var/log/app.log\techo done"

      changeset =
        ActionRun.Changeset.transition(%ActionRun{}, :succeeded, %{executed_command: program})

      assert get_change(changeset, :executed_command) == program
    end
  end
end
