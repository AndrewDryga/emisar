defmodule Emisar.Fixtures.Approvals do
  @moduledoc """
  Approval test inspectors. Use via `alias Emisar.Fixtures` then
  `Fixtures.Approvals.grants_for_api_key/1`.
  """

  import Ecto.Changeset, only: [change: 2]
  alias Emisar.{ActionContract, Approvals, Fixtures, Repo, Runbooks}
  alias Emisar.Catalog.{MCPProjection, TrustedManifest}

  @doc """
  Persists a `:pending` approval request by default. Caller supplies
  `:account_id` (a run is created in it) or `:run_id`. Override `:status` (sets
  `decided_at`) and `:requested_at` (to land it in a report window).
  """
  def create_request(attrs \\ %{}) do
    attrs = Map.new(attrs)

    run =
      if attrs[:run_id],
        do: nil,
        else: Fixtures.Runs.create_run(Map.take(attrs, [:account_id]))

    params = %{
      account_id: attrs[:account_id] || run.account_id,
      run_id: attrs[:run_id] || run.id,
      requested_at: attrs[:requested_at] || DateTime.utc_now(),
      reason: attrs[:reason]
    }

    {:ok, request} = params |> Approvals.Request.Changeset.create() |> Repo.insert()

    case attrs[:status] do
      status when is_atom(status) and not is_nil(status) ->
        request
        |> change(
          status: status,
          decided_at: attrs[:decided_at] || DateTime.utc_now(),
          decided_by_id: attrs[:decided_by_id],
          decision_reason: attrs[:decision_reason]
        )
        |> Repo.update!()

      nil ->
        request
    end
  end

  @doc "Marks a request approved as setup state for concurrent-flow tests."
  def approve_request(%Approvals.Request{} = request, decided_by_id) do
    request
    |> change(status: :approved, decided_at: DateTime.utc_now(), decided_by_id: decided_by_id)
    |> Repo.update!()
  end

  @doc "Persists one pending whole-execution request for approval UI tests."
  def create_execution_request(account, requested_by, attrs \\ %{}) do
    attrs = Map.new(attrs)
    executable? = Map.get(attrs, :executable?, false)

    runbook =
      Fixtures.Runbooks.create_runbook(
        account_id: account.id,
        created_by_id: requested_by.id,
        title: attrs[:runbook_title] || "Database maintenance"
      )

    membership = Fixtures.Memberships.fetch_membership(account.id, requested_by.id)

    stage_plan =
      attrs[:stage_plan] ||
        %{
          "id" => "apply",
          "title" => "Apply database change",
          "mode" => "parallel",
          "max_parallel" => 2,
          "items" => [
            %{
              "action" => "postgres.config_validate",
              "step_id" => "validate-primary",
              "runner_ref" => "db-01~" <> String.duplicate("1", 64),
              "pack_ref" => "postgres@1.4.2/sha256:" <> String.duplicate("a", 64),
              "risk" => "medium",
              "args" => %{"token" => "[REDACTED]"}
            },
            %{
              "action" => "postgres.config_validate",
              "step_id" => "validate-replica",
              "runner_ref" => "db-02~" <> String.duplicate("2", 64),
              "pack_ref" => "postgres@1.4.2/sha256:" <> String.duplicate("a", 64),
              "risk" => "medium",
              "args" => %{}
            }
          ]
        }

    execution =
      Runbooks.RunbookExecution.Changeset.create(%{
        id: Ecto.UUID.generate(),
        account_id: account.id,
        runbook_id: runbook.id,
        initiating_membership_id: membership.id,
        requested_by_id: requested_by.id,
        reason: attrs[:reason] || "Apply the reviewed database settings",
        frozen_plan: %{"schema_version" => 1, "stages" => [stage_plan]},
        inputs_raw: "{}",
        inputs_sha256: String.duplicate("0", 64),
        definition: runbook.draft_definition,
        definition_sha256: Runbooks.Definition.digest(runbook.draft_definition),
        kind: attrs[:execution_kind] || :published,
        status: :pending_approval
      })
      |> Repo.insert!()

    stage =
      Runbooks.ExecutionStage.Changeset.create(%{
        id: Ecto.UUID.generate(),
        account_id: account.id,
        runbook_execution_id: execution.id,
        stage_id: stage_plan["id"],
        position: 0,
        title: stage_plan["title"],
        mode: stage_plan["mode"],
        max_parallel: stage_plan["max_parallel"],
        status: :pending
      })
      |> Repo.insert!()

    policy =
      Fixtures.Policies.create_policy(
        account_id: account.id,
        created_by_id: requested_by.id
      )

    targets =
      stage_plan["items"]
      |> Enum.with_index()
      |> Enum.map(fn {item, position} ->
        runner =
          Fixtures.Runners.create_runner(
            account_id: account.id,
            name: "approval-target-#{position + 1}",
            group: "approval-targets",
            connected?: executable?
          )

        {:ok, {pack_id, pack_version, pack_hash}} =
          MCPProjection.parse_pack_ref(item["pack_ref"])

        action =
          if executable? do
            Fixtures.Catalog.create_action(
              runner: runner,
              action_id: item["action"],
              pack_id: pack_id,
              pack_version: pack_version,
              pack_hash: pack_hash,
              risk: item["risk"] || "medium",
              primary_executable_available: true
            )
          end

        %{
          action: action,
          frozen: item,
          pack_hash: pack_hash,
          pack_id: pack_id,
          pack_version: pack_version,
          position: position,
          runner: runner
        }
      end)

    if executable? do
      targets
      |> Enum.group_by(&{&1.pack_id, &1.pack_version, &1.pack_hash})
      |> Enum.each(fn {{pack_id, pack_version, pack_hash}, pack_targets} ->
        {:ok, trusted_manifest} =
          pack_targets
          |> Enum.map(& &1.action)
          |> TrustedManifest.from_runner_actions()

        Fixtures.Catalog.create_trusted_pack_version(
          account_id: account.id,
          pack_id: pack_id,
          version: pack_version,
          hash: pack_hash,
          trusted_manifest: trusted_manifest
        )
      end)
    end

    Enum.each(targets, fn target ->
      action_contract =
        if executable? do
          {:ok, manifest} = TrustedManifest.from_runner_actions([target.action])
          {:ok, descriptors} = TrustedManifest.actions(manifest)

          target.action.action_id
          |> then(&Map.fetch!(descriptors, &1))
          |> ActionContract.snapshot()
        else
          %{}
        end

      %Runbooks.ExecutionItem{
        id: Ecto.UUID.generate(),
        account_id: account.id,
        runbook_execution_id: execution.id,
        runbook_execution_stage_id: stage.id,
        stage_position: 0,
        step_id: target.frozen["step_id"],
        step_position: target.position,
        runner_id: target.runner.id,
        runner_ref: target.frozen["runner_ref"],
        target_selection: "all",
        action_id: target.frozen["action"],
        pack_ref: target.frozen["pack_ref"],
        pack_hash: target.pack_hash,
        risk: target.frozen["risk"],
        action_contract: action_contract,
        policy_id: policy.id,
        policy_version: policy.vsn,
        policy_decision: "require_approval",
        policy_reason: "Fixture requires approval"
      }
      |> Repo.insert!()
    end)

    Approvals.Request.Changeset.create(%{
      account_id: account.id,
      runbook_execution_id: execution.id,
      requested_by_id: requested_by.id,
      requested_at: DateTime.utc_now(),
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      reason: execution.reason,
      min_approvals: attrs[:min_approvals] || 1,
      allow_self_approval: Map.get(attrs, :allow_self_approval, true),
      context: %{
        "kind" => "runbook_execution",
        "execution_kind" => to_string(execution.kind),
        "execution_id" => execution.id,
        "runbook" => %{
          "id" => runbook.id,
          "title" => runbook.title,
          "version" => runbook.live_version
        },
        "plan" => execution.frozen_plan
      }
    })
    |> Repo.insert!()
  end

  @doc "Moves a held request's deadline; the TTL is stamped at creation, so expiry cases set it."
  def set_request_expiry(%Approvals.Request{} = request, %DateTime{} = expires_at) do
    request
    |> change(expires_at: expires_at)
    |> Repo.update!()
  end

  @doc "Moves a held request to its run-cancelled terminal state for stale-decision tests."
  def cancel_request(%Approvals.Request{} = request, reason \\ "The run was cancelled.") do
    request
    |> change(
      status: :cancelled,
      decided_at: DateTime.utc_now(),
      decision_reason: reason
    )
    |> Repo.update!()
  end

  @doc """
  Test-side inspector: the unrevoked grants minted against an API key,
  newest first. Verifies `approve_request/4` side effects without
  rebuilding the Subject-gated operator surface in test setup.
  """
  def grants_for_api_key(api_key_id) do
    Approvals.Grant.Query.not_revoked()
    |> Approvals.Grant.Query.by_api_key_id(api_key_id)
    |> Approvals.Grant.Query.ordered_by_recent()
    |> Repo.all()
  end
end
