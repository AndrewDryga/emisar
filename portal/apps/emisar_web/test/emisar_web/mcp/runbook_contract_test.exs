defmodule EmisarWeb.MCP.RunbookContractTest do
  use ExUnit.Case, async: true
  alias Emisar.Runbooks.Runbook
  alias EmisarWeb.MCP.RunbookContract

  @pack_ref "operations@1.0.0/sha256:" <> String.duplicate("b", 64)

  test "accepts the exact maximum expansion and rejects each larger dimension" do
    snapshot = snapshot(16)

    assert {:ok, public} = RunbookContract.project(runbook(32, 8), snapshot)
    assert length(public.steps) == 32

    assert {:error, :incomplete_contract} =
             RunbookContract.project(runbook(33, 1), snapshot)

    assert {:error, :incomplete_contract} =
             RunbookContract.project(runbook(1, 17), snapshot(17))

    assert {:error, :incomplete_contract} =
             RunbookContract.project(runbook(17, 16), snapshot)
  end

  test "rejects a public definition over 56 KiB even when each argument object is bounded" do
    runbook = runbook(3, 1, String.duplicate("a", 20_000))

    assert {:error, :incomplete_contract} = RunbookContract.project(runbook, snapshot(1))
  end

  test "group selectors fail closed when any matching account runner is outside caller scope" do
    [visible, hidden] = runners(2)
    action = action([visible.id, hidden.id])

    snapshot = %{
      packs: [%{pack_ref: @pack_ref, actions: [action]}],
      runners: [visible],
      account_runners: [visible, hidden]
    }

    runbook = %Runbook{
      slug: "group-book",
      version: 1,
      title: "Group book",
      description: "Checks a complete group.",
      definition: %{"steps" => [step(1, %{"group" => ["fleet"]}, %{})]}
    }

    assert {:error, :incomplete_contract} = RunbookContract.project(runbook, snapshot)
  end

  test "resolves a missing pack ref and keeps a group visible with one compatible member" do
    [connected, offline] = runners(2)
    action = action([connected.id])

    snapshot = %{
      packs: [%{pack_ref: @pack_ref, actions: [action]}],
      runners: [connected, offline],
      account_runners: [connected, offline]
    }

    definition =
      %{"steps" => [step(1, %{"group" => ["fleet"]}, %{}) |> Map.delete("pack_ref")]}

    runbook = %Runbook{
      slug: "partial-group-book",
      version: 1,
      title: "Partial group book",
      description: "Checks an available group member.",
      definition: definition
    }

    assert {:ok, public} = RunbookContract.project(runbook, snapshot)
    assert [%{pack_ref: @pack_ref, runner_selector: %{groups: ["fleet"]}}] = public.steps
  end

  test "resolved plans repeat the same per-step and total ceilings" do
    assert RunbookContract.valid_plan_size?(plan(16, 16))
    refute RunbookContract.valid_plan_size?(plan(1, 17))
    refute RunbookContract.valid_plan_size?(plan(17, 16))
    refute RunbookContract.valid_plan_size?([])
  end

  defp snapshot(runner_count) do
    runners = runners(runner_count)

    %{
      packs: [%{pack_ref: @pack_ref, actions: [action(Enum.map(runners, & &1.id))]}],
      runners: runners,
      account_runners: runners
    }
  end

  defp runbook(step_count, runner_count, payload \\ nil) do
    selected = Enum.map(1..runner_count, &"runner-#{&1}")
    args = if payload, do: %{"payload" => payload}, else: %{}

    %Runbook{
      slug: "bounded-book",
      version: 1,
      title: "Bounded book",
      description: "Exercises fixed MCP limits.",
      definition: %{
        "steps" => Enum.map(1..step_count, &step(&1, %{"runner_id" => selected}, args))
      }
    }
  end

  defp step(index, selector, args) do
    %{
      "id" => "step-#{index}",
      "action_id" => "operations.health",
      "pack_ref" => @pack_ref,
      "args" => args,
      "runner_selector" => selector
    }
  end

  defp runners(count) do
    Enum.map(1..count, fn index ->
      %{
        id: "runner-#{index}",
        runner_ref: "runner-#{index}~#{String.duplicate(Integer.to_string(rem(index, 10)), 32)}",
        group: "fleet"
      }
    end)
  end

  defp action(runner_ids) do
    %{
      "action_id" => "operations.health",
      "args_schema" => %{
        "args" => [
          %{"name" => "payload", "type" => "string", "required" => false}
        ]
      },
      compatible_runner_ids: runner_ids
    }
  end

  defp plan(step_count, runners_per_step) do
    for step <- 1..step_count, runner <- 1..runners_per_step do
      %{step_id: "step-#{step}", runner_id: "runner-#{runner}"}
    end
  end
end
