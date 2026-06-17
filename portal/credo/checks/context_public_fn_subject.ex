defmodule Emisar.Checks.ContextPublicFnSubject do
  use Credo.Check,
    base_priority: :higher,
    category: :design,
    explanations: [
      check: """
      Iron Law IL-3: the context is the authorization boundary. A PUBLIC
      context function that touches the database (`Repo.*`) must take a
      `%Auth.Subject{}` so it can gate the access — OR declare itself a
      sanctioned subject-less path:

        * an already-authorized internal helper marked `@doc "Internal …"`
          (or `@doc false`) — §1.4: runner-socket advertisers, Oban sweepers,
          the SCIM/auth lifecycle, session plumbing; or
        * a pre-auth path that threads a `%RequestContext{}` instead of a
          subject (sign-in, magic link, password reset, email confirm — §1.2).

      The annotation/shape makes every subject-less DB path explicit and
      auditable — the web/MCP can only reach one when it is declared. Scoped to
      context modules (`lib/emisar/<context>.ex`) and to public defs that call
      `Repo.*` directly; pure helpers and `change_*/2` builders (no DB) are not
      matched.
      """
    ]

  @infra ~w(repo application release mailer telemetry pubsub pub_sub)
  @exempt_structs [:Subject, :RequestContext]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if relevant?(source_file.filename) do
      ctx =
        Context.build(source_file, params, __MODULE__, %{
          pending_doc: nil,
          internal_fns: MapSet.new()
        })

      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  defp relevant?(filename) do
    case Regex.run(~r{/lib/emisar/([a-z_0-9]+)\.ex$}, filename) do
      [_, name] -> name not in @infra
      nil -> false
    end
  end

  # Track the @doc immediately preceding a def.
  defp walk({:@, _, [{:doc, _, [value]}]} = ast, ctx) do
    {ast, %{ctx | pending_doc: classify_doc(value)}}
  end

  # Public def: judge it, then clear the pending @doc. `@doc` attaches to a function's
  # FIRST clause, so an Internal mark carries to its later clauses (tracked by name) —
  # otherwise a multi-clause helper's Repo-touching clause would fire with no doc.
  defp walk({:def, meta, [head | _]} = ast, ctx) do
    name = fn_name(head)
    internal? = ctx.pending_doc == :internal or MapSet.member?(ctx.internal_fns, name)
    exempt? = internal? or exempt_struct?(head) or not touches_repo?(ast)
    fns = if internal?, do: MapSet.put(ctx.internal_fns, name), else: ctx.internal_fns
    ctx = if exempt?, do: ctx, else: put_issue(ctx, issue_for(ctx, meta, name))
    {ast, %{ctx | pending_doc: nil, internal_fns: fns}}
  end

  # A private def consumes any pending @doc too.
  defp walk({:defp, _, _} = ast, ctx), do: {ast, %{ctx | pending_doc: nil}}

  defp walk(ast, ctx), do: {ast, ctx}

  defp classify_doc(false), do: :internal

  defp classify_doc(doc) when is_binary(doc),
    do: if(String.starts_with?(doc, "Internal"), do: :internal, else: :other)

  defp classify_doc(_), do: :other

  # A %Subject{} (gated) or %RequestContext{} (pre-auth shape, §1.2) anywhere in the head.
  defp exempt_struct?(head) do
    any_node?(head, fn
      {:%, _, [{:__aliases__, _, parts}, _]} -> List.last(parts) in @exempt_structs
      _ -> false
    end)
  end

  defp touches_repo?(node), do: any_node?(node, &repo_call?/1)

  defp repo_call?({{:., _, [{:__aliases__, _, parts}, fun]}, _, _}) when is_atom(fun),
    do: List.last(parts) == :Repo

  defp repo_call?(_), do: false

  defp any_node?(ast, pred) do
    {_, found} = Macro.prewalk(ast, false, fn node, acc -> {node, acc or pred.(node)} end)
    found
  end

  defp fn_name({:when, _, [inner | _]}), do: fn_name(inner)
  defp fn_name({name, _, _}) when is_atom(name), do: "#{name}"
  defp fn_name(_), do: "fn"

  defp issue_for(ctx, meta, name) do
    format_issue(
      ctx,
      message:
        "IL-3: public context fn `#{name}` calls Repo without a %Subject{} — take a " <>
          "subject to gate it, mark it `@doc \"Internal …\"` if it is an already-authorized " <>
          "internal helper, or thread a %RequestContext{} if it is a pre-auth path.",
      trigger: name,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
