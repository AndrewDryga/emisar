defmodule EmisarWeb.MCP.InputContractTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.MCP.InputContract

  @pack_ref "operations@1.0.0/sha256:" <> String.duplicate("a", 64)
  @runner_ref "node~" <> String.duplicate("b", 32)

  test "rejects strings for published integer and boolean fields" do
    assert {:error, [%{path: "$.limit", code: "type"}]} =
             InputContract.validate("list_runners", %{"limit" => "50"})

    assert {:error, [%{path: "$.issues_only", code: "type"}]} =
             InputContract.validate("list_runners", %{"issues_only" => "true"})
  end

  test "rejects non-object arguments and normalizes schema-valid integral numbers" do
    assert {:error, [%{path: "$", code: "type"}]} = InputContract.validate("list_packs", false)
    assert {:ok, %{"limit" => 50}} = InputContract.validate("list_packs", %{"limit" => 50.0})
    assert {:ok, %{"limit" => 15}} = InputContract.validate("recent_runs", %{"limit" => 15.0})
  end

  test "bounds reason to the published 2000-character limit" do
    action = valid_action_args(%{"reason" => String.duplicate("😀", 2_000)})
    assert {:ok, _arguments} = InputContract.validate("run_action", action)

    action = valid_action_args(%{"reason" => String.duplicate("😀", 2_001)})

    assert {:error, [%{path: "$.reason", code: "max_length"}]} =
             InputContract.validate("run_action", action)

    action = valid_action_args(%{"reason" => "   "})

    assert {:error, [%{path: "$.reason", code: "format"}]} =
             InputContract.validate("run_action", action)
  end

  test "accepts the optional evidence/expected chain and bounds each" do
    action =
      valid_action_args(%{
        "evidence" => "prior run 0f9c showed disk at 98%",
        "expected" => "df reports under 80% after cleanup"
      })

    assert {:ok, arguments} = InputContract.validate("run_action", action)
    assert arguments["evidence"] == "prior run 0f9c showed disk at 98%"
    assert arguments["expected"] == "df reports under 80% after cleanup"

    over_evidence = valid_action_args(%{"evidence" => String.duplicate("e", 4_001)})

    assert {:error, [%{path: "$.evidence", code: "max_length"}]} =
             InputContract.validate("run_action", over_evidence)

    over_expected = valid_action_args(%{"expected" => String.duplicate("x", 2_001)})

    assert {:error, [%{path: "$.expected", code: "max_length"}]} =
             InputContract.validate("run_action", over_expected)

    blank_evidence = valid_action_args(%{"evidence" => "   "})

    assert {:error, [%{path: "$.evidence", code: "format"}]} =
             InputContract.validate("run_action", blank_evidence)
  end

  test "preserves specific JSONSchex size and uniqueness rules" do
    assert {:error, [%{path: "$.query", code: "max_length"}]} =
             InputContract.validate("list_runners", %{"query" => String.duplicate("x", 257)})

    runner_ref = @runner_ref

    assert {:error, [%{path: "$.runner_refs", code: "unique"}]} =
             InputContract.validate("list_runners", %{"runner_refs" => [runner_ref, runner_ref]})

    assert {:error, [%{path: "$.limit", code: "min"}]} =
             InputContract.validate("list_packs", %{"limit" => 0})
  end

  test "unknown tools and root fields fail closed" do
    assert {:error, [%{path: "$", code: "schema"}]} =
             InputContract.validate("not_a_tool", %{})

    assert {:error, [%{path: "$.junk", code: "unknown"}]} =
             InputContract.validate("list_packs", %{"junk" => 1})
  end

  test "exposes published root argument names for safe log paths" do
    assert MapSet.member?(InputContract.known_root_fields("list_packs"), "limit")
    assert MapSet.member?(InputContract.known_root_fields("run_action"), "action_id")
    assert InputContract.known_root_fields("not_a_tool") == MapSet.new()
  end

  defp valid_action_args(overrides) do
    Map.merge(
      %{
        "action_id" => "demo.inspect",
        "pack_ref" => @pack_ref,
        "runner_refs" => [@runner_ref],
        "args" => %{},
        "reason" => "Inspect"
      },
      overrides
    )
  end
end
