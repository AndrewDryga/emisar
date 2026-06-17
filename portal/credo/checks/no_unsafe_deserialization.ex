defmodule Emisar.Checks.NoUnsafeDeserialization do
  use Credo.Check,
    base_priority: :higher,
    category: :warning,
    explanations: [
      check: """
      Security: never deserialize or evaluate untrusted input. emisar ingests
      bytes from runners and LLMs, so:

        * `:erlang.binary_to_term/1` is forbidden — it can construct arbitrary
          terms (funs, atoms, pids) and is a remote-code / atom-exhaustion
          vector. Use `binary_to_term(bin, [:safe])` if you must, or a typed
          decoder (`Jason`).
        * `Code.eval_string` / `eval_quoted` / `eval_file` evaluate code at
          runtime — never on any value that can carry input.

      Complements `UnsafeToAtom` (IL-14) and `NoProcessDictionary`.
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if String.contains?(source_file.filename, "/lib/") and
         not String.contains?(source_file.filename, "/test/") do
      ctx = Context.build(source_file, params, __MODULE__)
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  # :erlang.binary_to_term(bin) — unsafe unless called with the [:safe] option.
  defp walk({{:., _, [:erlang, :binary_to_term]}, meta, args} = ast, ctx) when is_list(args) do
    if safe_btt?(args),
      do: {ast, ctx},
      else: {ast, put_issue(ctx, issue_for(ctx, meta, ":erlang.binary_to_term"))}
  end

  # Code.eval_string / eval_quoted / eval_file
  defp walk({{:., _, [{:__aliases__, meta, parts}, fun]}, _, args} = ast, ctx)
       when fun in [:eval_string, :eval_quoted, :eval_file] and is_list(args) do
    if List.last(parts) == :Code,
      do: {ast, put_issue(ctx, issue_for(ctx, meta, "Code.#{fun}"))},
      else: {ast, ctx}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp safe_btt?([_bin, opts]) when is_list(opts), do: :safe in opts
  defp safe_btt?(_), do: false

  defp issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "Security: #{trigger} can execute or construct arbitrary terms from input — " <>
          "use a typed decoder (Jason) or `binary_to_term(bin, [:safe])`; never eval input.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
