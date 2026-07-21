defmodule Emisar.ContextCoverageTest do
  @moduledoc """
  Enforces the house rule: **every public function in a domain context has a
  function-named `describe "fun/arity"` somewhere in the test suite.**
  For a `def f(a, b \\ [])`, the written max arity (`f/2`) is the coverage key;
  the compiler-generated `f/1` default wrapper is considered covered by that
  describe. If a lower arity has distinct behavior, make it an explicit `def`
  and it will need its own describe.

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
    accounts admin api_keys approvals audit auth billing catalog mail marketing mcp_operations
    oauth policies runbooks runners runs sso users
  ]a

  @otp_lifecycle_callbacks MapSet.new([{"init", 1}, {"start_link", 1}])

  # Every function name covered by a `describe "name/arity …"` across the WHOLE
  # test tree (both apps) — a context's functions may be tested in sibling files.
  defp described_functions do
    [Path.join(__DIR__, ".."), Path.join([__DIR__, "..", "..", "..", "emisar_web", "test"])]
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.exs")))
    |> Enum.flat_map(fn file ->
      ~r/describe\s+"([a-z_]+[!?]?)\/(\d+)/
      |> Regex.scan(File.read!(file))
      |> Enum.map(fn [_match, name, arity] -> {name, String.to_integer(arity)} end)
    end)
    |> MapSet.new()
  end

  defp public_functions(context_name) do
    [__DIR__, "..", "..", "lib", "emisar", "#{context_name}.ex"]
    |> Path.join()
    |> File.read!()
    |> Code.string_to_quoted!()
    |> public_defs()
  end

  defp public_defs(ast) do
    {_ast, defs} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:def, _meta, [head | _body]} = node, defs ->
          {node, MapSet.put(defs, function_name_and_arity(head))}

        node, defs ->
          {node, defs}
      end)

    MapSet.difference(defs, @otp_lifecycle_callbacks)
  end

  defp function_name_and_arity({:when, _meta, [head | _guards]}),
    do: function_name_and_arity(head)

  defp function_name_and_arity({name, _meta, args}) when is_atom(name) and is_list(args),
    do: {Atom.to_string(name), length(args)}

  defp function_name_and_arity({name, _meta, _context}) when is_atom(name),
    do: {Atom.to_string(name), 0}

  defp format_function({name, arity}), do: "#{name}/#{arity}"

  setup_all do
    {:ok, described: described_functions()}
  end

  for context_name <- @contexts do
    @context_name context_name
    test "Emisar.#{context_name |> Atom.to_string() |> Macro.camelize()} — every public function has a describe",
         %{described: described} do
      gap =
        @context_name
        |> public_functions()
        |> MapSet.difference(described)
        |> Enum.sort()
        |> Enum.map(&format_function/1)

      assert gap == [],
             "#{@context_name}.ex has PUBLIC functions with no `describe` anywhere in the suite: " <>
               "#{inspect(gap)}. Add `describe \"<fun>/<arity>\"` (with real tests, in module " <>
               "order) to test/emisar/#{@context_name}_test.exs."
    end
  end
end
