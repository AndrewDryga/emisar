defmodule Emisar.Checks.NoUnsafeDeserialization do
  use Credo.Check,
    base_priority: :higher,
    category: :warning,
    explanations: [
      check: """
      Security: never deserialize or evaluate untrusted input. emisar ingests
      bytes from runners and LLMs, so the External Term Format is not an input
      format here — decode with `Jason` and rebuild the term from values you
      whitelist.

          # ❌ — all three decode attacker bytes into a term
          :erlang.binary_to_term(cursor)
          :erlang.binary_to_term(cursor, [:safe])
          Plug.Crypto.non_executable_binary_to_term(cursor, [:safe])

          # ✅ — bound the bytes, then decode into typed values
          with {:ok, json} <- Base.url_decode64(cursor, padding: false),
               true <- byte_size(json) <= @max_decoded_cursor_bytes,
               {:ok, [direction, values]} <- Jason.decode(json) do

      `:safe` is not a size bound, and neither is the non-executable filter.
      Both constrain which terms may be BUILT — no new atoms, no funs — not how
      large they may be. ETF carries zlib-compressed payloads that
      `binary_to_term` inflates transparently, so a few hundred bytes on the
      wire become an arbitrarily larger term. `non_executable_binary_to_term/2`
      is no better: it decodes in full and only then walks the result rejecting
      funs, so the allocation has already happened by the time it can object.
      That is CVE-2026-69659 (Ash keyset cursors) — a list of repeated small
      integers amplified several orders of magnitude, rejected for its shape
      only after it had been allocated.

      Where ETF is genuinely unavoidable, a documented
      `# credo:disable-for-next-line Emisar.Checks.NoUnsafeDeserialization`
      under its why-comment needs BOTH guards before the decode; neither alone
      is sufficient, and no AST check can see that they are actually there:

        1. Refuse compression. A compressed payload starts
           `<<131, 80, uncompressed_size::32, _::binary>>`, so match
           `<<131, 80, _::binary>>` and reject — viable wherever our own encoder
           does not compress, which covers every round-trip design we have.
           (Bounding against that declared size is the alternative: the runtime
           enforces the declaration during decode, so a payload that misreports
           it fails, which makes it trustworthy as a filter.)
        2. Bound the raw byte size. An uncompressed payload declares nothing and
           still allocates in proportion to its length, so the compression check
           alone leaves the cheaper attack wide open.

      `Emisar.Repo.Paginator` is the worked example of the preferred shape: a
      JSON envelope, an encoded-size guard on the decode function head before
      any Base64 decode, and a decoded-size guard before `Jason.decode` — with
      the compressed-ETF amplification pinned by its own regression test.

      `Code.eval_string` / `eval_quoted` / `eval_file` evaluate code at runtime —
      never on any value that can carry input.

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

  # :erlang.binary_to_term(bin) / (bin, opts) — `[:safe]` earns no exemption:
  # it constrains which terms may be built, never how large they may be.
  defp walk({{:., _, [:erlang, :binary_to_term]}, meta, args} = ast, ctx) when is_list(args) do
    {ast, put_issue(ctx, decode_issue_for(ctx, meta, ":erlang.binary_to_term"))}
  end

  # Plug.Crypto.non_executable_binary_to_term/1,2 — decodes in full, filters
  # after, so it carries the identical amplification profile. Matched on the
  # function name alone because no other module defines it, however it's aliased.
  defp walk(
         {{:., _, [{:__aliases__, meta, parts}, :non_executable_binary_to_term]}, _, args} = ast,
         ctx
       )
       when is_list(args) do
    trigger = Enum.map_join(parts ++ [:non_executable_binary_to_term], ".", &Atom.to_string/1)
    {ast, put_issue(ctx, decode_issue_for(ctx, meta, trigger))}
  end

  # Code.eval_string / eval_quoted / eval_file
  defp walk({{:., _, [{:__aliases__, meta, parts}, fun]}, _, args} = ast, ctx)
       when fun in [:eval_string, :eval_quoted, :eval_file] and is_list(args) do
    if List.last(parts) == :Code,
      do: {ast, put_issue(ctx, eval_issue_for(ctx, meta, "Code.#{fun}"))},
      else: {ast, ctx}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp decode_issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "Security: #{trigger} builds a term from input before anything can bound its " <>
          "size — ETF inflates compressed payloads transparently, and neither `:safe` nor " <>
          "the non-executable filter is a size bound. Use a typed decoder (Jason).",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end

  defp eval_issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "Security: #{trigger} evaluates code at runtime — never on any value that can " <>
          "carry runner, LLM, or operator input.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
