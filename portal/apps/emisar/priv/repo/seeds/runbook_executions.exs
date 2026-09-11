defmodule Emisar.Seeds.RunbookExecutions do
  @moduledoc """
  Execution history for the rollout runbook — one success, one denied, and one
  current whole-run approval — plus the TLS rotation's approval backlog, and
  the real-shaped attempt output behind the completed execution.
  """

  alias Emisar.Approvals
  alias Emisar.Approvals.Request, as: ApprovalRequest
  alias Emisar.Audit
  alias Emisar.Repo
  alias Emisar.Runbooks
  alias Emisar.Runbooks.{ExecutionItem, ExecutionStage, Runbook, RunbookExecution}
  alias Emisar.Runbooks.Extractor
  alias Emisar.Runners
  alias Emisar.Runs
  alias Emisar.Runs.ActionRun
  alias Emisar.Seeds.{Fleet, Helpers}

  # -- Runbook execution history + whole-run approval ------------------
  #
  # The readiness runbook intentionally stays empty. The rollout runbook carries
  # one success, one denied execution, and one current whole-plan approval so the
  # console's empty, history, and pending states are all visible after one reset.
  # These rows are demo fixtures, so rerunning seeds replaces only this runbook's
  # executions instead of accumulating another story.

  @doc "Adds `seeded_execution_ids`, `succeeded_at`, and `succeeded_finished_at` to the context."
  def run(%{approval_runbook: approval_runbook, backlog_runbook: backlog_runbook} = ctx) do
    Enum.each([approval_runbook, backlog_runbook], &delete_executions/1)

    seeded_execution_ids = dispatch_executions(ctx)

    # `Approvals.expire_overdue_requests/1` flips anything past `expires_at`, and
    # the policy's 24h window is why this account's curated pending approvals
    # decayed over a few days; the backlog carries a change-freeze-length window
    # instead so the queue survives until the next reseed.
    backlog_expires_at = Helpers.days_out(21)

    Enum.each(seeded_execution_ids.backlog, fn execution_id ->
      ApprovalRequest.Query.all()
      |> ApprovalRequest.Query.by_runbook_execution_id(execution_id)
      |> Repo.update_all(set: [expires_at: backlog_expires_at])
    end)

    succeeded_at = Helpers.hours_ago(4)
    succeeded_finished_at = DateTime.add(succeeded_at, 18, :second)
    settle_succeeded(ctx, seeded_execution_ids.succeeded, succeeded_at, succeeded_finished_at)
    settle_halted(seeded_execution_ids.halted)
    backdate_execution(seeded_execution_ids.pending, Helpers.mins_ago(8))

    %ApprovalRequest{status: :pending} = fetch_execution_request(seeded_execution_ids.pending)

    Helpers.say("✓ Seeded runbook empty state, execution history, and whole-run approval")

    Map.merge(ctx, %{
      seeded_execution_ids: seeded_execution_ids,
      succeeded_at: succeeded_at,
      succeeded_finished_at: succeeded_finished_at
    })
  end

  defp delete_executions(%Runbook{} = runbook) do
    RunbookExecution.Query.by_runbook_id(runbook.id)
    |> Repo.all()
    |> Enum.each(fn execution ->
      ActionRun.Query.all()
      |> ActionRun.Query.by_runbook_execution_id(execution.id)
      |> Repo.delete_all()
    end)

    RunbookExecution.Query.by_runbook_id(runbook.id)
    |> Repo.delete_all()
  end

  # Dispatch needs the edge runners connected; connect the ones that are not,
  # and hand them back to their seeded offline history afterwards.
  defp dispatch_executions(
         %{
           account: account,
           runners: runners,
           jordan: jordan,
           approval_runbook: approval_runbook,
           backlog_runbook: backlog_runbook
         } = ctx
       ) do
    temporary_connections =
      runners
      |> Enum.filter(&(&1.group == "edge-web"))
      |> Enum.flat_map(fn runner ->
        if Runners.online?(account.id, runner.id) do
          []
        else
          case Runners.connect_runner(runner) do
            {:ok, connected} -> [connected]
            {:error, :already_connected} -> []
          end
        end
      end)

    jordan_subject = Helpers.subject_for(account, jordan)

    # A distinct region + cause per request, so the queue reads as real work.
    backlog_reasons = [
      "Rotate the eu-central edge certificates - the 90-day certificate window closes on Sunday.",
      "Rotate the us-east-1 edge certificates - the upstream intermediate CA was rotated."
    ]

    try do
      succeeded_id =
        dispatch_seed_execution(
          ctx,
          approval_runbook,
          "Reload the validated Caddyfile during the completed Tuesday maintenance window."
        )

      halted_id =
        dispatch_seed_execution(
          ctx,
          approval_runbook,
          "Reload the edge configuration before the change window has opened."
        )

      halted_request = fetch_execution_request(halted_id)

      {:ok, {%ApprovalRequest{status: :denied}, :runbook_execution}} =
        Approvals.deny_request(
          halted_request,
          jordan_subject,
          "Wait for the approved change window."
        )

      pending_id =
        dispatch_seed_execution(
          ctx,
          approval_runbook,
          "Roll out the validated Caddyfile during the scheduled edge maintenance window."
        )

      backlog_ids =
        Enum.map(backlog_reasons, &dispatch_seed_execution(ctx, backlog_runbook, &1))

      %{succeeded: succeeded_id, halted: halted_id, pending: pending_id, backlog: backlog_ids}
    after
      Enum.each(temporary_connections, fn connected ->
        {:ok, disconnected} =
          Runners.disconnect_runner(
            connected.id,
            connected.connection_generation,
            connected.connection_lease_id,
            "seed preflight complete"
          )

        Fleet.restore_runner_state(disconnected)
      end)
    end
  end

  defp fetch_execution_request(execution_id) do
    ApprovalRequest.Query.all()
    |> ApprovalRequest.Query.by_runbook_execution_id(execution_id)
    |> Repo.one!()
  end

  defp dispatch_seed_execution(%{owner_subject: owner_subject}, %Runbook{} = runbook, reason) do
    {:ok, %{execution_id: execution_id, runs: []}} =
      Runbooks.dispatch_runbook(runbook, reason, owner_subject)

    %RunbookExecution{status: :pending_approval} =
      RunbookExecution.Query.by_id(execution_id)
      |> Repo.one!()

    execution_id
  end

  defp backdate_execution(execution_id, timestamp) do
    RunbookExecution.Query.by_id(execution_id)
    |> Repo.one!()
    |> Ecto.Changeset.change(inserted_at: timestamp, updated_at: timestamp)
    |> Repo.update!()

    ExecutionStage.Query.by_execution_id(execution_id)
    |> Repo.update_all(set: [inserted_at: timestamp, updated_at: timestamp])

    ExecutionItem.Query.by_execution_id(execution_id)
    |> Repo.update_all(set: [inserted_at: timestamp, updated_at: timestamp])

    ApprovalRequest.Query.all()
    |> ApprovalRequest.Query.by_runbook_execution_id(execution_id)
    |> Repo.update_all(
      set: [
        requested_at: timestamp,
        expires_at: DateTime.add(timestamp, 24 * 3600, :second),
        inserted_at: timestamp,
        updated_at: timestamp
      ]
    )
  end

  # Approved by Jordan, every item and stage run to success, the whole execution
  # settled four hours ago.
  defp settle_succeeded(%{jordan: jordan}, execution_id, succeeded_at, succeeded_finished_at) do
    execution_id
    |> fetch_execution_request()
    |> Ecto.Changeset.change(
      status: :approved,
      decided_by_id: jordan.id,
      decided_at: DateTime.add(succeeded_at, 5, :second),
      decision_reason: "Validated config, drained connections, and an open change window."
    )
    |> Repo.update!()

    ExecutionItem.Query.by_execution_id(execution_id)
    |> Repo.all()
    |> Enum.each(fn item ->
      {outputs, outputs_raw, outputs_sha256, evidence} =
        if item.output_plan == [] and item.success_plan == [] do
          {%{}, nil, nil, []}
        else
          {:ok, result} =
            Extractor.evaluate_materialized(
              item.output_plan,
              item.success_plan,
              %{
                "structured_output" => %{"healthy" => true, "upstreams" => 2},
                "stdout" => "{\"healthy\":true,\"upstreams\":2}\n",
                "stderr" => ""
              }
            )

          raw = Jason.encode!(result.raw)
          digest = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
          {result.public, raw, digest, result.evidence}
        end

      item
      |> ExecutionItem.Changeset.succeed(
        outputs,
        outputs_raw,
        outputs_sha256,
        evidence,
        succeeded_finished_at
      )
      |> Ecto.Changeset.change(
        attempt_count: 1,
        started_at: DateTime.add(succeeded_at, 6, :second)
      )
      |> Repo.update!()
    end)

    ExecutionStage.Query.by_execution_id(execution_id)
    |> Repo.all()
    |> Enum.each(fn stage ->
      stage
      |> ExecutionStage.Changeset.succeed(succeeded_finished_at)
      |> Ecto.Changeset.change(started_at: DateTime.add(succeeded_at, 6, :second))
      |> Repo.update!()
    end)

    RunbookExecution.Query.by_id(execution_id)
    |> Repo.one!()
    |> RunbookExecution.Changeset.succeed(succeeded_finished_at)
    |> Repo.update!()

    backdate_execution(execution_id, succeeded_at)
  end

  # Denied yesterday; the execution, its stages, items, and request all close
  # three seconds after it was raised.
  defp settle_halted(execution_id) do
    halted_at = Helpers.days_ago(1)
    halted_finished_at = DateTime.add(halted_at, 3, :second)
    backdate_execution(execution_id, halted_at)

    RunbookExecution.Query.by_id(execution_id)
    |> Repo.update_all(
      set: [
        completed_at: halted_finished_at,
        updated_at: halted_finished_at
      ]
    )

    ExecutionStage.Query.by_execution_id(execution_id)
    |> Repo.update_all(set: [finished_at: halted_finished_at, updated_at: halted_finished_at])

    ExecutionItem.Query.by_execution_id(execution_id)
    |> Repo.update_all(set: [finished_at: halted_finished_at, updated_at: halted_finished_at])

    ApprovalRequest.Query.all()
    |> ApprovalRequest.Query.by_runbook_execution_id(execution_id)
    |> Repo.update_all(set: [decided_at: halted_finished_at, updated_at: halted_finished_at])
  end

  # -- Runbook action output previews ----------------------------------

  @doc """
  Gives the completed runbook execution real-shaped physical attempts and
  bounded output, so its detail page demonstrates the same action-output review
  operators get from a live execution. This stays outside the general run seed
  guard: rerunning seeds replaces the runbook executions above, then recreates
  exactly one attempt per completed item here.
  """
  def seed_output_previews(%{
        account: account,
        user: user,
        owner_membership: owner_membership,
        approval_runbook: approval_runbook,
        seeded_execution_ids: seeded_execution_ids,
        succeeded_at: succeeded_at,
        succeeded_finished_at: succeeded_finished_at
      }) do
    succeeded_execution =
      RunbookExecution.Query.by_id(seeded_execution_ids.succeeded)
      |> Repo.one!()

    ExecutionItem.Query.by_execution_id(seeded_execution_ids.succeeded)
    |> Repo.all()
    |> Enum.each(fn item ->
      Helpers.seed_terminal_history(fn ->
        args = if is_binary(item.args_raw), do: Jason.decode!(item.args_raw), else: %{}

        {:ok, attempt} =
          Runs.create_run(%{
            account_id: account.id,
            runner_id: item.runner_id,
            action_id: item.action_id,
            args: args,
            reason: succeeded_execution.reason,
            # A runbook stage's attempt — the scheduler writes `source: :runbook`,
            # so seeding it as `operator` left the runs list's "Dispatched by →
            # Runbook" filter matching nothing in the demo account.
            source: "runbook",
            requested_by_id: user.id,
            initiating_membership_id: owner_membership.id,
            pack_ref: item.pack_ref,
            runner_ref: item.runner_ref,
            runbook_id: approval_runbook.id,
            runbook_step_id: item.step_id,
            runbook_execution_id: seeded_execution_ids.succeeded,
            runbook_execution_item_id: item.id,
            attempt_number: 1,
            expected_pack_hash: item.pack_hash,
            policy_id: item.policy_id,
            policy_version: item.policy_version,
            policy_decision: "allow",
            policy_reason:
              item.policy_reason <> " The approved runbook plan authorized this execution.",
            status: "running"
          })

        Enum.with_index(preview_chunks(item), 1)
        |> Enum.each(fn {{stream, chunk}, seq} ->
          {:ok, _event} =
            Runs.append_event(attempt, %{
              seq: seq,
              kind: "progress",
              stream: stream,
              payload: %{"chunk" => chunk}
            })
        end)

        # The runs list orders by insertion and the audit trail records every
        # terminal run, so the attempt lands where its execution sits in the
        # timeline — not at seed time — and leaves a receipt like a live run would.
        finished_attempt =
          attempt
          |> ActionRun.Changeset.transition(:success, %{
            started_at: DateTime.add(succeeded_at, 6, :second),
            finished_at: succeeded_finished_at,
            exit_code: 0,
            duration_ms: 12_000,
            output_complete: true,
            executed_command: executed_command(item),
            event_id: "seed-runbook-" <> item.id
          })
          |> Repo.update!()
          |> Ecto.Changeset.change(inserted_at: succeeded_at, queued_at: succeeded_at)
          |> Repo.update!()

        finished_attempt
        |> Repo.preload(:runner)
        |> Audit.run_event_changeset()
        |> Ecto.Changeset.change(occurred_at: succeeded_finished_at)
        |> Repo.insert!()

        finished_attempt
      end)
    end)

    Helpers.say("✓ Seeded runbook action output previews")
  end

  defp preview_chunks(%ExecutionItem{action_id: "caddy.reload_config"} = item) do
    runner_name = item.runner_ref |> String.split("~") |> hd()

    [
      {"stdout", "Valid configuration\n"},
      {"stdout", "Reloaded Caddy configuration on #{runner_name}\n"}
    ]
  end

  defp preview_chunks(%ExecutionItem{action_id: "caddy.version"}) do
    [{"stdout", "v2.8.4 h1:0n6wXAMXxVqI9eD/9KspXHiCmGX95e9FQeawhe2iZHQ=\n"}]
  end

  defp preview_chunks(%ExecutionItem{action_id: "caddy.reverse_proxy_upstreams"}) do
    [{"stdout", "{\"healthy\":true,\"upstreams\":2}\n"}]
  end

  defp preview_chunks(%ExecutionItem{}) do
    [{"stdout", "Action completed successfully\n"}]
  end

  defp executed_command(%ExecutionItem{action_id: "caddy.reload_config"}),
    do: "caddy reload --config /etc/caddy/Caddyfile"

  defp executed_command(%ExecutionItem{action_id: "caddy.version"}), do: "caddy version"

  defp executed_command(%ExecutionItem{action_id: "caddy.reverse_proxy_upstreams"}),
    do: ~s(/bin/sh -c 'curl -fsS "${CADDY_ADMIN:-http://127.0.0.1:2019}/reverse_proxy/upstreams"')

  defp executed_command(%ExecutionItem{}), do: nil
end
