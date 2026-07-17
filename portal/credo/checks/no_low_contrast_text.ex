defmodule Emisar.Checks.NoLowContrastText do
  use Credo.Check,
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      `text-zinc-600` (#52525b) is 2.3-2.7:1 on the console's near-black grounds
      (zinc-950 / black / zinc-900), so it fails WCAG AA for BOTH normal and large
      text everywhere — there is no size at which it clears the bar. The design
      system (`.agent/rules/design-system.md`, "Contrast (WCAG AA)") already
      prescribes the fix: `text-zinc-400` (~7.8:1) is the AA-safe muted tier for any
      essential secondary text, and it stays quieter than the zinc-300 body / zinc-100
      headings, so raising the token preserves the de-emphasis register.

          # ❌ — essential text an operator reads, below AA at every size
          <p class="text-xs text-zinc-600">The leading space keeps the key out of history.</p>

          # ✅ — the AA-safe muted tier for essential secondary text
          <p class="text-xs text-zinc-400">The leading space keeps the key out of history.</p>

          # ✅ — a genuinely decorative glyph / icon clears the 3:1 non-text bar at zinc-500
          <span class="select-none text-zinc-500">$</span>
          <.icon name="hero-arrow-top-right-on-square" class="h-3.5 w-3.5 text-zinc-500" />

      Only the RESTING text color is flagged. Variant-prefixed uses stay — a
      `placeholder:text-zinc-600` hint in a labeled field, a `[&_li]:marker:` bullet,
      a `hover:`/`group-hover:` state — because they are decorative or supplementary
      and not the resting foreground; the lookbehind skips anything preceded by `:`.

      This check is deliberately scoped to `text-zinc-600` only. `text-zinc-500`
      (~4:1) is SIZE-DEPENDENT — it fails AA for normal text but PASSES AA-large
      (≥24px, or ≥18.66px bold), so a large eyebrow/heading may legitimately keep it
      and a static AST check cannot decide that from the class string. zinc-500 on
      small essential text is a review rule (design-system), not a mechanical one.

      A deliberate exception is marked with a HEEx comment on the line DIRECTLY above
      the tag (the check reads the marker itself; Credo's own disable comments don't
      reach inside an ~H sigil):

          <%!-- credo:disable-for-next-line Emisar.Checks.NoLowContrastText — why --%>
          <span class="text-zinc-600">…</span>
      """
    ]

  alias Credo.IssueMeta
  alias Credo.SourceFile

  # The RESTING text color `text-zinc-600` (any opacity), NOT a variant like
  # `placeholder:`/`hover:`/`marker:` (those are preceded by `:`) — the lookbehind
  # rejects a leading `:`/word/`-`, so only a token-boundary resting color matches.
  @resting_zinc_600 ~r/(?<![:\w-])text-zinc-600(?![\w-])/

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if String.contains?(source_file.filename, "apps/emisar_web/lib/emisar_web/") do
      issue_meta = IssueMeta.for(source_file, params)
      source = SourceFile.source(source_file)
      lines = String.split(source, "\n")

      @resting_zinc_600
      |> Regex.scan(source, return: :index)
      |> Enum.map(fn [{start, _length}] -> line_no(source, start) end)
      |> Enum.reject(&disabled?(lines, &1))
      |> Enum.map(&issue_for(issue_meta, &1))
    else
      []
    end
  end

  defp line_no(source, start) do
    source |> binary_part(0, start) |> String.split("\n") |> length()
  end

  defp disabled?(lines, line_no) do
    case Enum.at(lines, line_no - 2) do
      nil ->
        false

      previous ->
        String.contains?(previous, "credo:disable-for-next-line") and
          String.contains?(previous, "NoLowContrastText")
    end
  end

  defp issue_for(issue_meta, line_no) do
    format_issue(
      issue_meta,
      message:
        "text-zinc-600 fails WCAG AA at every size on the near-black grounds (2.3-2.7:1). " <>
          "Use text-zinc-400 for essential text (the AA-safe muted tier), or text-zinc-500 for a " <>
          "genuinely decorative glyph/icon (clears the 3:1 non-text bar). A placeholder:/marker:/" <>
          "hover: variant is exempt; a deliberate exception uses a credo:disable HEEx comment above.",
      line_no: line_no
    )
  end
end
