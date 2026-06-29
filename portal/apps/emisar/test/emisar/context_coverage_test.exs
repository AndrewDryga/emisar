defmodule Emisar.ContextCoverageTest do
  @moduledoc """
  Enforces the house rule: **every public function in a domain context has a
  function-named `describe "fun/arity"` somewhere in the test suite.**

  A failure here means a public context function shipped with no test — exactly
  the gap the describe-order rule (§7: describes follow the module's function
  order) exists to surface. Fix it by adding a `describe "fun/arity"` with real
  tests (happy / denial / cross-account, per §7) to the context's
  `<ctx>_test.exs`, in module-function order — not by editing this file.

  Infra modules (`Repo`, `PubSub`, `Crypto`, `Telemetry`, …) are not domain
  contexts and are out of scope. When a NEW context is added, add it to
  `@contexts` below (and to its test).
  """
  use ExUnit.Case, async: true

  @contexts ~w[
    accounts api_keys approvals audit auth billing catalog mail oauth
    policies runbooks runners runs sso users
  ]a

  # Every function name covered by a `describe "name/arity …"` across the WHOLE
  # test tree (both apps) — a context's functions may be tested in sibling files.
  defp described_function_names do
    [Path.join(__DIR__, ".."), Path.join([__DIR__, "..", "..", "..", "emisar_web", "test"])]
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.exs")))
    |> Enum.flat_map(fn file ->
      ~r/describe\s+"([a-z_]+[!?]?)\//
      |> Regex.scan(File.read!(file))
      |> Enum.map(&Enum.at(&1, 1))
    end)
    |> MapSet.new()
  end

  defp public_function_names(ctx) do
    [__DIR__, "..", "..", "lib", "emisar", "#{ctx}.ex"]
    |> Path.join()
    |> File.read!()
    # name only — no trailing `(`, so parenless public defs (`def plans, do:`,
    # `def list_running_runs do`) are covered too, not silently skipped.
    |> then(&Regex.scan(~r/^  def ([a-z_]+[!?]?)/m, &1))
    |> Enum.map(&Enum.at(&1, 1))
    |> MapSet.new()
  end

  setup_all do
    {:ok, described: described_function_names()}
  end

  for ctx <- @contexts do
    @ctx ctx
    test "Emisar.#{ctx |> Atom.to_string() |> Macro.camelize()} — every public function has a describe",
         %{described: described} do
      gap =
        @ctx
        |> public_function_names()
        |> MapSet.difference(described)
        |> Enum.sort()

      assert gap == [],
             "#{@ctx}.ex has PUBLIC functions with no `describe` anywhere in the suite: " <>
               "#{inspect(gap)}. Add `describe \"<fun>/<arity>\"` (with real tests, in module " <>
               "order) to test/emisar/#{@ctx}_test.exs."
    end
  end
end
