defmodule Emisar.Checks.MultilineDoColon do
  use Credo.Check,
    base_priority: :high,
    category: :readability,
    explanations: [
      check: """
      House rule: a `, do:` one-liner is only for a body that FITS on one line.
      When the body is long enough that the formatter wraps `do:` onto its own
      line, write a regular `do … end` block instead — for `def`/`defp` bodies
      and inline `if/unless(…, do: …, else: …)` alike.

          # ❌ — the formatter wrapped `do:` down; the body sits on its own line
          defp reduced?(a, b),
            do:
              not MapSet.subset?(perms(a), perms(b))

          # ✅
          defp reduced?(a, b) do
            not MapSet.subset?(perms(a), perms(b))
          end

      The mechanical signature is a source line that is exactly `do:` — the
      keyword with its value wrapped onto the next line. `, do: short_body` that
      still fits on one line is fine; only the wrapped form is flagged.
      """
    ]

  alias Credo.IssueMeta
  alias Credo.SourceFile

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    source_file
    |> SourceFile.lines()
    |> Enum.filter(fn {_line_no, line} -> String.trim(line) == "do:" end)
    |> Enum.map(fn {line_no, _line} -> issue_for(issue_meta, line_no) end)
  end

  defp issue_for(issue_meta, line_no) do
    format_issue(
      issue_meta,
      message:
        "`do:` wrapped onto its own line — the body is too long for a `, do:` " <>
          "one-liner. Use a `do … end` block instead.",
      line_no: line_no
    )
  end
end
