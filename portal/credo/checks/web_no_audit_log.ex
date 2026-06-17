defmodule Emisar.Checks.WebNoAuditLog do
  use Credo.Check,
    base_priority: :higher,
    category: :design,
    explanations: [
      check: """
      House rule (§1): audit is a domain concern. The context function that
      performs a mutation writes its OWN audit row via
      `Multi.insert(:audit, Audit.Events.<event>(...))` — controllers and
      LiveViews never call `Audit.log*` or hand-build `Audit.Events.*` rows.
      (e.g. the session controller calls `Accounts.record_sign_in/2`, which
      owns the `user.signed_in` audit row.)

      Reads through the `Audit` context (`Audit.list_events/2`, …) are fine —
      only the write helpers (`Audit.log*`, `Audit.record`, `Audit.Events.*`) are matched.
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if String.contains?(source_file.filename, "apps/emisar_web/lib/") do
      ctx = Context.build(source_file, params, __MODULE__)
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  defp walk({{:., _, [{:__aliases__, meta, parts}, fun]}, _, args} = ast, ctx)
       when is_atom(fun) and is_list(args) do
    cond do
      Enum.take(parts, -2) == [:Audit, :Events] ->
        {ast, put_issue(ctx, issue_for(ctx, meta, "Audit.Events.#{fun}"))}

      List.last(parts) == :Audit and audit_write?(fun) ->
        {ast, put_issue(ctx, issue_for(ctx, meta, "Audit.#{fun}"))}

      true ->
        {ast, ctx}
    end
  end

  defp walk(ast, ctx), do: {ast, ctx}

  # The Audit context's write API — `log`, `log_for_user`, `record` — never from the web.
  defp audit_write?(fun) do
    name = Atom.to_string(fun)
    String.starts_with?(name, "log") or name == "record"
  end

  defp issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "House rule: #{trigger} in the web layer — audit is a domain concern. " <>
          "Call the context function that performs the mutation; it writes its own audit row.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
