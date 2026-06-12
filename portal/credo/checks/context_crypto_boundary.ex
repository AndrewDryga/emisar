defmodule Emisar.Checks.ContextCryptoBoundary do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      House rule: all crypto goes through `Emisar.Crypto`.

      A context (or changeset/query module) calling `:crypto.*` or
      encoding a secret with `Base.url_encode64` inline scatters the RNG,
      encoding, and hash choices a security product wants auditable in
      one place. Mint/hash/compare through the named `Emisar.Crypto`
      functions instead. (Vendor-protocol seams like the Paddle webhook
      HMAC and content-digest helpers live in their own submodules, which
      this check deliberately doesn't cover.)
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if relevant?(source_file.filename) do
      ctx = Context.build(source_file, params, __MODULE__)
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  # Top-level context modules + the pure changeset/query satellites.
  defp relevant?(filename) do
    not String.ends_with?(filename, "lib/emisar/crypto.ex") and
      (Regex.match?(~r{apps/emisar/lib/emisar/[a-z_0-9]+\.ex$}, filename) or
         String.ends_with?(filename, "/changeset.ex") or
         String.ends_with?(filename, "/query.ex"))
  end

  defp walk({{:., _, [:crypto, fun]}, meta, args} = ast, ctx)
       when is_atom(fun) and is_list(args) do
    {ast, put_issue(ctx, issue_for(ctx, meta, ":crypto.#{fun}"))}
  end

  defp walk({{:., _, [{:__aliases__, meta, [:Base]}, :url_encode64]}, _, args} = ast, ctx)
       when is_list(args) do
    {ast, put_issue(ctx, issue_for(ctx, meta, "Base.url_encode64"))}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "House rule: inline #{trigger} in a context — route secrets and digests " <>
          "through Emisar.Crypto (one auditable crypto surface).",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
