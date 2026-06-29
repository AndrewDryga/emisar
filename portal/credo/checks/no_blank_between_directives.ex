defmodule Emisar.Checks.NoBlankBetweenDirectives do
  use Credo.Check,
    base_priority: :high,
    category: :readability,
    explanations: [
      check: """
      House rule: the module header is ONE contiguous block — no blank line
      between the `use` / `import` / `alias` / `require` directives.

          # ❌ — the default ExUnit/Phoenix shape
          use Emisar.DataCase, async: true

          alias Emisar.Accounts

          # ✅
          use Emisar.DataCase, async: true
          alias Emisar.Accounts

      The stock `StrictModuleLayout` check enforces the directive ORDER
      (`use` → `import` → `alias` → `require`) but not their contiguity; this
      catches a blank line sandwiched between two of them. Exception: the
      blank `mix format` itself inserts before a MULTI-LINE directive
      (`use Phoenix.VerifiedRoutes,\n  endpoint: …`) is left alone — fighting
      the formatter is futile.
      """
    ]

  alias Credo.IssueMeta
  alias Credo.SourceFile

  @directive ~r/^\s*(?:use|import|alias|require)\s/

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    source_file
    |> SourceFile.lines()
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.filter(fn [{_, a}, {_, blank}, {_, c}] ->
      directive?(a) and String.trim(blank) == "" and directive?(c) and not multiline_start?(c)
    end)
    |> Enum.map(fn [_, {blank_line_no, _}, _] -> issue_for(issue_meta, blank_line_no) end)
  end

  defp directive?(line), do: Regex.match?(@directive, line)

  # `mix format` puts a blank line before a directive whose options wrap onto
  # the next line (its first line ends with `,`) — don't fight that.
  defp multiline_start?(line), do: line |> String.trim_trailing() |> String.ends_with?(",")

  defp issue_for(issue_meta, line_no) do
    format_issue(
      issue_meta,
      message:
        "Blank line between module-header directives — keep `use`/`import`/" <>
          "`alias`/`require` as one contiguous block.",
      line_no: line_no
    )
  end
end
