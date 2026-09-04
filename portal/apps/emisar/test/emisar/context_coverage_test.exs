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

  **And the counterpart: every public context function has a CALLER in `lib/`.**
  Requiring a test without requiring a caller is what let dozens of public
  functions accumulate with no production consumer — each one green, each one
  carrying a describe that existed only to satisfy the rule above. A superseded
  function keeps its tests passing forever, so tests alone cannot tell live
  surface from dead surface. `SSO.scim_patch_group_members/5` sat that way after
  `scim_patch_group/3` replaced it, still cited as the live path in the SCIM
  group controller's moduledoc, until this check surfaced it.

  Both checks share the same weakness and accept it: they match on NAME, so a
  same-named function in an unrelated module can mask a gap. That is a floor,
  not a ceiling — it catches the shape that actually recurs (a function nobody
  calls, or nobody tests) without a compiler-grade call graph.

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

  # Deliberate inspection surface with no Elixir caller. Keep this list at the
  # size of its evidence — each entry names why deleting it would lose something.
  #
  # `Admin.job_modules/0` exposes the `@job_modules` supervision list that
  # `admin_test.exs` uses to assert every recurrent job is disabled in the test
  # env (three had leaked and ticked inside the sandbox, reading as flakes).
  # A module attribute is not readable at runtime, so the alternative is a second
  # copy of the list in `test/support` — which would silently stop covering newly
  # added jobs, defeating the test.
  @inspection_surface MapSet.new([{:admin, {"job_modules", 0}}])

  # Intended API surface: Subject-gated reads and operator actions kept
  # deliberately, decided 2026-08-08. Each is a capability the product owns, and
  # each carries denial + cross-account tests that are genuine security coverage
  # — that coverage only exists against a Subject-gated context function, so
  # moving these to `test/support` would delete it rather than relocate it
  # (`list_pack_versions/2` alone backs 99 call sites).
  #
  # `peek_enrollment_key_by_secret/1` is the read-only inspector for "is this
  # enrollment secret currently usable?" — registration deliberately does NOT
  # use it, claiming the key transactionally instead (see its @doc).
  #
  # `compose_dispatch_batch_in_multi/5` stays because it is the only way to
  # assert the post-commit contract of the LIVE
  # `after_composed_dispatches_committed/1`: that composing a batch does NOT
  # deliver or broadcast until its outer transaction commits. The runbook
  # sibling cannot express it (it demands a full execution-item graph whose
  # identity guard the fixture would have to fake), and the MCP path commits
  # and fires the side effects in one step, so neither can prove the negative.
  #
  # `close_account/3` is the staff account-closure verb, run from a release
  # shell. The founder kept it on 2026-09-04 when the caller walk stopped
  # counting prose: its scope and denial tests are the security coverage the
  # audit tightened (AC-1), and a console surface is a later product decision.
  #
  # Do NOT add to this list to silence a new failure. A newly written function
  # with no caller is dead on arrival; this list is a decision that was made
  # once, about surface that already existed.
  @intended_api_surface MapSet.new([
                          {:accounts, {"close_account", 3}},
                          {:accounts, {"list_memberships_for_account", 3}},
                          {:approvals, {"revoke_all_grants", 1}},
                          {:catalog, {"check_pack_trusted", 1}},
                          {:catalog, {"list_pack_versions", 2}},
                          {:runners, {"peek_enrollment_key_by_secret", 1}},
                          {:runs, {"compose_dispatch_batch_in_multi", 5}},
                          {:runs, {"list_runs_by_runbook_execution", 2}}
                        ])

  # Every `describe "name/arity …"` across both test trees, kept with the module
  # names its file mentions.
  #
  # A context's functions may legitimately be tested in a sibling file — the
  # runner-scope and invitation suites are topical, and a web controller test
  # drives the context function behind it — so this cannot be narrowed to one
  # file per context. But matching on the describe NAME alone let any context
  # borrow another's coverage: the suite's only `describe "refresh/2"` is in the
  # pack-registry cache test, which never mentions OAuth, and it was the thing
  # marking `Emisar.OAuth.refresh/2` covered. Deleting every OAuth test would
  # not have failed this check.
  #
  # So a describe counts for a context only if its file actually references that
  # context — the weakest binding that still rules out an unrelated namesake.
  defp described_functions do
    [Path.join(__DIR__, ".."), Path.join([__DIR__, "..", "..", "..", "emisar_web", "test"])]
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.exs")))
    |> Enum.flat_map(fn file ->
      source = File.read!(file)

      ~r/describe\s+"([a-z_][a-z_0-9]*[!?]?)\/(\d+)/
      |> Regex.scan(source)
      |> Enum.map(fn [_match, name, arity] ->
        {{name, String.to_integer(arity)}, referenced_contexts(source)}
      end)
    end)
    |> Enum.reduce(%{}, fn {key, contexts}, acc ->
      Map.update(acc, key, contexts, &MapSet.union(&1, contexts))
    end)
  end

  defp referenced_contexts(source) do
    @contexts
    |> Enum.filter(fn context ->
      module = context_module(context)
      String.contains?(source, "Emisar.#{module}") or String.contains?(source, "#{module}.")
    end)
    |> MapSet.new()
  end

  # Read the module name from the context's own source rather than camelizing
  # its filename: the acronym contexts are Emisar.SSO, Emisar.OAuth and
  # Emisar.MCPOperations, which Macro.camelize/1 renders Sso, Oauth and
  # McpOperations — three names that appear nowhere.
  defp context_module(context) do
    [__DIR__, "..", "..", "lib", "emisar", "#{context}.ex"]
    |> Path.join()
    |> File.read!()
    |> then(&Regex.run(~r/^defmodule\s+Emisar\.([A-Za-z0-9_.]+)\s+do/m, &1))
    |> Enum.at(1)
  end

  defp public_functions(context_name) do
    [__DIR__, "..", "..", "lib", "emisar", "#{context_name}.ex"]
    |> Path.join()
    |> File.read!()
    |> Code.string_to_quoted!()
    |> public_defs()
  end

  # `defdelegate` is public surface like any `def` — the caller sees one function
  # either way, and a delegated name that nothing calls or tests is exactly the
  # dead surface both halves of this test exist to find.
  defp public_defs(ast) do
    {_ast, defs} =
      Macro.prewalk(ast, MapSet.new(), fn
        {kind, _meta, [head | _rest]} = node, defs when kind in [:def, :defdelegate] ->
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

  # Every `lib/` source across both apps, so a caller in the web adapter counts
  # just as much as one in a sibling context — plus `seeds.exs`, which is
  # committed non-test code that `./run seed` must keep running, so a function
  # only the seeds drive is consumed, not dead.
  #
  # Each source is reduced to the names it CALLS, read off its AST. Matching the
  # source TEXT instead counted a name written in a `@doc` heredoc or a comment,
  # so a documented-but-uncalled function passed as live — the exact shape this
  # half of the test exists to catch.
  defp lib_sources do
    [
      Path.join([__DIR__, "..", "..", "lib"]),
      Path.join([__DIR__, "..", "..", "..", "emisar_web", "lib"])
    ]
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.{ex,heex}")))
    |> Enum.concat(Path.wildcard(Path.join([__DIR__, "..", "..", "priv", "repo", "seeds.exs"])))
    |> Enum.map(&{Path.expand(&1), called_names(&1)})
  end

  # `{remote, local}`: names reached through a module (`Mod.fun(…)`, `&Mod.fun/1`)
  # and names called bare. A `.heex` template has no Elixir AST — and no
  # docstrings or `#` comments either — so it keeps a text scan.
  defp called_names(path) do
    source = File.read!(path)

    if Path.extname(path) == ".heex" do
      {template_names(source), MapSet.new()}
    else
      {_ast, names} =
        source
        |> Code.string_to_quoted!()
        |> Macro.prewalk({MapSet.new(), MapSet.new()}, &collect_call/2)

      names
    end
  end

  # `Mod.fun(…)`, `Mod.fun`, and the `&Mod.fun/1` capture's inner node. A
  # PARENLESS dot on a variable is a struct/map field read (`account.plan`) and
  # has the identical AST shape, so the target is what tells the two apart.
  defp collect_call({{:., _, [target, name]}, meta, _args} = node, {remote, local})
       when is_atom(name) do
    if meta[:no_parens] == true and not module_target?(target),
      do: {node, {remote, local}},
      else: {node, {MapSet.put(remote, Atom.to_string(name)), local}}
  end

  # `&fun/1` — a local capture; the name node carries a context atom, not args.
  defp collect_call({:&, _, [{:/, _, [{name, _, ctx}, _arity]}]} = node, {remote, local})
       when is_atom(name) and is_atom(ctx),
       do: {node, {remote, MapSet.put(local, Atom.to_string(name))}}

  # A literal `~H` body reaches the AST as a string, so a call written in the
  # template would otherwise be invisible to the walk.
  defp collect_call({:sigil_H, _, [{:<<>>, _, parts}, _modifiers]} = node, {remote, local}) do
    names =
      parts
      |> Enum.filter(&is_binary/1)
      |> Enum.reduce(remote, &MapSet.union(template_names(&1), &2))

    {node, {names, local}}
  end

  # A definition head is shaped exactly like a local call, so keep its arguments
  # (a default value can call something) and drop the name.
  defp collect_call({kind, meta, [head | rest]}, acc)
       when kind in [:def, :defp, :defmacro, :defmacrop, :defdelegate],
       do: {{kind, meta, [head_args(head) | rest]}, acc}

  defp collect_call({name, _meta, args} = node, {remote, local})
       when is_atom(name) and is_list(args),
       do: {node, {remote, MapSet.put(local, Atom.to_string(name))}}

  defp collect_call(node, acc), do: {node, acc}

  defp module_target?({:__aliases__, _meta, _parts}), do: true
  defp module_target?(target) when is_atom(target), do: true
  defp module_target?(_target), do: false

  defp head_args({:when, meta, [head | guards]}), do: {:when, meta, [head_args(head) | guards]}
  defp head_args({name, _meta, args}) when is_atom(name) and is_list(args), do: args
  defp head_args(head), do: head

  defp template_names(source) do
    ~r/\.([a-z_][a-z_0-9]*[!?]?)\s*[(\/]/
    |> Regex.scan(source)
    |> MapSet.new(fn [_match, name] -> name end)
  end

  defp context_path(context_name),
    do: Path.expand(Path.join([__DIR__, "..", "..", "lib", "emisar", "#{context_name}.ex"]))

  # A function is "called" if some other lib file reaches it through a module,
  # or its own module calls it bare — a public function used only by its own
  # module is still live code, just misplaced.
  defp called?(sources, definer, {name, _arity}) do
    Enum.any?(sources, fn {path, {remote, local}} ->
      MapSet.member?(remote, name) or (path == definer and MapSet.member?(local, name))
    end)
  end

  setup_all do
    {:ok, described: described_functions(), sources: lib_sources()}
  end

  for context_name <- @contexts do
    @context_name context_name
    test "Emisar.#{context_name |> Atom.to_string() |> Macro.camelize()} — every public function has a describe",
         %{described: described} do
      covered? = &MapSet.member?(Map.get(described, &1, MapSet.new()), @context_name)

      gap =
        @context_name
        |> public_functions()
        |> Enum.reject(covered?)
        |> Enum.sort()
        |> Enum.map(&format_function/1)

      assert gap == [],
             "#{@context_name}.ex has PUBLIC functions with no `describe` in a file that " <>
               "references this context: #{inspect(gap)}. Add `describe \"<fun>/<arity>\"` " <>
               "(with real tests, in module order) to test/emisar/#{@context_name}_test.exs."
    end

    test "Emisar.#{context_name |> Atom.to_string() |> Macro.camelize()} — every public function has a caller",
         %{sources: sources} do
      definer = context_path(@context_name)

      gap =
        @context_name
        |> public_functions()
        |> Enum.reject(fn function ->
          key = {@context_name, function}

          MapSet.member?(@inspection_surface, key) or
            MapSet.member?(@intended_api_surface, key) or
            called?(sources, definer, function)
        end)
        |> Enum.sort()
        |> Enum.map(&format_function/1)

      assert gap == [],
             "#{@context_name}.ex has PUBLIC functions nothing in lib/ calls: #{inspect(gap)}. " <>
               "A tested-but-uncalled function is dead surface the describe check cannot see — " <>
               "delete it and its describe, or make it private. If a non-Elixir entry point " <>
               "calls it (a release script, an OTP callback), exclude it here and name that " <>
               "entry point in a comment."
    end
  end
end
