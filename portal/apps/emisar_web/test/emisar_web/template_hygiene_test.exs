defmodule EmisarWeb.TemplateHygieneTest do
  @moduledoc """
  Mechanical markup rules over every rendered template in `emisar_web`.

  These live here rather than in `credo/checks/` because **Credo cannot parse
  `.heex`** — it reports the file as unparseable and drops it from the run, so a
  Credo check would only ever see the `~H` sigils embedded in `.ex` files. The
  inline-punctuation rule below shipped 8 violations across six files while its grep
  sat documented-but-unrun in `portal/AGENTS.md`; six of those eight were in
  `.heex` files a Credo check could not have reached.

  A rule belongs in this file when it is decidable from the template SOURCE
  TEXT and its subject includes `.heex`. Anything decidable from Elixir AST
  stays a `Emisar.Checks.*` Credo check.
  """
  use ExUnit.Case, async: true

  @web_lib Path.join([__DIR__, "..", "..", "lib"])

  # Whitespace between an inline closing tag and punctuation renders as a
  # visible space — "require_approval ." The formatter preserves adjacency.
  @inline_prose_punctuation_gap ~r{</(?:a|span|code|strong|em|small|time|kbd|samp|abbr|mark|q|cite|del|ins|sub|sup|\.(?:link|external_link|doc_link))>[ \t\r\n]+[.,;:!?]}

  # A `:for` concatenates its elements with no whitespace between them and each
  # is `whitespace-nowrap`, so an inline run has no soft-wrap opportunity and
  # becomes one unbreakable line that overflows once the list is long enough.
  # Only visible at real data volumes — a fleet advertising dozens of runners.
  @repeated_inline ~r{^\s*<\.(?:chip|badge|identity_tag)\s+:for[=\s]}

  # `x["key"] != []` is an equality test, not a list check: a map with no such
  # key compares as non-empty, so the guard passes and hands the comprehension
  # behind it a nil. Only a hazard when the two read the SAME raw expression —
  # normalizing once into an assign makes them agree by construction.
  @raw_subscript_for ~r/:for=\{[^}]*<-\s*([^}]*\["[a-z_]+"\])\s*\}/

  # A marketing CTA label is prose — long enough to wrap on a phone — so the
  # arrow must ride in the text flow, glued to the last word. Plain whitespace
  # before it is a line-break opportunity, and `<.cta_arrow>` is an inline-block
  # element, so the break drops the arrow onto its own line. (Console nav CTAs
  # are short fixed labels — "View activity" — inside an `inline-flex` link that
  # cannot wrap, which is why this pair of rules is scoped to marketing.)
  @detached_cta_arrow ~r{[ \t\r\n]<\.cta_arrow}

  # `cta_link` glues the arrow to whatever its slot renders, so slot content
  # that starts or ends with template whitespace puts a breakable space back.
  @unglued_cta_link_slot ~r{<\.cta_link[^>]*>[ \t\r\n]|[ \t\r\n]</\.cta_link>}

  # Clamping ONE axis with `-hidden` forces the other to compute to `auto` (CSS
  # Overflow 3), so the element silently becomes a scroll container that swallows
  # every absolutely-positioned overlay hanging out of it. The console shell's
  # `<main>` ate the whole `Actions ▾` panel on the last row of a list, and the
  # document could not even grow to reach it. `overflow-[xy]-clip` clamps the same
  # axis and leaves the other one `visible`.
  @single_axis_hidden ~r{\boverflow-[xy]-hidden\b}

  defp template_sources do
    [
      Path.wildcard(Path.join(@web_lib, "**/*.heex")),
      Path.wildcard(Path.join(@web_lib, "**/*.ex"))
    ]
    |> Enum.concat()
    |> Enum.map(&{Path.relative_to(&1, @web_lib), File.read!(&1)})
  end

  defp marketing_sources do
    Enum.filter(template_sources(), fn {file, _source} ->
      String.starts_with?(file, "emisar_web/controllers/marketing_html/") or
        file == "emisar_web/components/marketing_components.ex"
    end)
  end

  defp offending_marketing_matches(pattern) do
    for {file, source} <- marketing_sources(),
        [{byte_index, _length} | _captures] <- Regex.scan(pattern, source, return: :index),
        line_no =
          source |> binary_part(0, byte_index) |> :binary.matches("\n") |> length() |> Kernel.+(1),
        do: "#{file}:#{line_no}"
  end

  defp offending_source_matches(pattern) do
    for {file, source} <- template_sources(),
        [{byte_index, _length} | _captures] <- Regex.scan(pattern, source, return: :index),
        line_no =
          source |> binary_part(0, byte_index) |> :binary.matches("\n") |> length() |> Kernel.+(1),
        do: "#{file}:#{line_no}"
  end

  # The formatter normalizes HEEx indentation, so the nearest preceding line at a
  # strictly smaller indent that opens an element IS the enclosing element. Its
  # attributes may wrap, so read forward to the line that closes the open tag.
  defp enclosing_open_tag(lines, index) do
    indent = leading_spaces(Enum.at(lines, index))

    lines
    |> Enum.take(index)
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value("", fn {line, line_index} ->
      trimmed = String.trim_leading(line)

      if String.starts_with?(trimmed, "<") and not String.starts_with?(trimmed, "</") and
           leading_spaces(line) < indent do
        lines |> Enum.slice(line_index..index) |> Enum.join(" ")
      end
    end)
  end

  defp leading_spaces(nil), do: 0
  defp leading_spaces(line), do: String.length(line) - String.length(String.trim_leading(line))

  test "a repeated inline element rendered by a comprehension sits in a flex-wrap container" do
    offenders =
      for {file, source} <- template_sources(),
          lines = String.split(source, "\n"),
          {line, index} <- Enum.with_index(lines),
          Regex.match?(@repeated_inline, line),
          parent = enclosing_open_tag(lines, index),
          not (String.contains?(parent, "flex-wrap") and String.contains?(parent, "flex")),
          do: "#{file}:#{index + 1}"

    assert offenders == [],
           """
           A repeated inline element rendered by `:for` sits in a parent that is not a
           flex-wrap container. The comprehension emits the elements with no whitespace
           between them and each is `whitespace-nowrap`, so the run has no soft-wrap
           opportunity and overflows the page once the list is long enough.

           Put the lead-in prose in its own element and the repeated elements in a
           sibling `flex flex-wrap gap-*`; the container's gap replaces any per-item
           `ml-*`. Verify at the widest list, not a two-item demo.

           Offending lines (relative to apps/emisar_web/lib):
           #{Enum.map_join(offenders, "\n", &"  #{&1}")}
           """
  end

  test "a comprehension does not re-read a raw subscript its guard already tested" do
    offenders =
      for {file, source} <- template_sources(),
          lines = String.split(source, "\n"),
          {line, index} <- Enum.with_index(lines),
          [_match, subscript] <- Regex.scan(@raw_subscript_for, line),
          guard = enclosing_open_tag(lines, index),
          String.contains?(guard, subscript <> " != []") or
            String.contains?(guard, subscript <> " == []"),
          do: "#{file}:#{index + 1}"

    assert offenders == [],
           """
           A `:for` walks the same raw subscript expression its enclosing element
           compares to `[]`. That comparison is not a list check — a map with no such
           key is not equal to `[]`, so the guard passes and the comprehension receives
           nil, raising Protocol.UndefinedError and taking the whole page down.

           Normalize once into an assign so the guard and the walk cannot disagree:

               ✅  assigns = assign(assigns, :inputs, definition["inputs"] || [])
                   <div :if={@inputs != []}><div :for={input <- @inputs}>

               ❌  <div :if={definition["inputs"] != []}>
                     <div :for={input <- definition["inputs"]}>

           See .agent/kb/rules/elixir-nil-is-not-an-empty-list.md.

           Offending lines (relative to apps/emisar_web/lib):
           #{Enum.map_join(offenders, "\n", &"  #{&1}")}
           """
  end

  test "a single-axis overflow clamp uses clip, never hidden" do
    offenders = offending_source_matches(@single_axis_hidden)

    assert offenders == [],
           """
           A single axis is clamped with `-hidden`. CSS Overflow 3 then computes the
           OTHER axis to `auto`, so the element becomes a scroll container nobody asked
           for — and it clips every absolutely-positioned overlay that hangs out of it.
           A dropdown panel or tooltip past its edge does not overflow the page, it
           disappears, and the document never grows for the operator to scroll to.

               ✅  <main class="flex-1 overflow-x-clip ...">
               ❌  <main class="flex-1 overflow-x-hidden ...">

           `clip` clamps the same axis and leaves the other `visible`. Both axes really
           needing containment is a different thing — plain `overflow-hidden` stays.

           Offending lines (relative to apps/emisar_web/lib):
           #{Enum.map_join(offenders, "\n", &"  #{&1}")}
           """
  end

  test "inline prose punctuation is glued to its preceding closing tag" do
    offenders = offending_source_matches(@inline_prose_punctuation_gap)

    assert offenders == [],
           """
           Whitespace sits between an inline closing tag and its punctuation, so it
           renders as a visible gap ("require_approval ." or "a shell ,").

           Glue punctuation directly to the closing tag. For links whose text otherwise
           moves to its own line, glue the text to both tags too:

               ✅  }>read the connection guide</.link>.
               ✅  <span>require_approval</span>.
               ❌  >
                     read the connection guide
                   </.link>
                   .
               ❌  <code>require_approval</code> ,

           Offending lines (relative to apps/emisar_web/lib):
           #{Enum.map_join(offenders, "\n", &"  #{&1}")}
           """
  end

  test "a marketing CTA arrow is glued to the last word of its label" do
    offenders = offending_marketing_matches(@detached_cta_arrow)

    assert offenders == [],
           """
           A `<.cta_arrow>` follows plain whitespace, so the line may break before it
           and strand the arrow away from the label it belongs to. A marketing CTA
           label wraps on a phone; the founder reported exactly this — the arrow
           floating mid-air beside a three-line block.

           Glue it with a non-breaking space, and never make the label and the arrow
           flex SIBLINGS (`inline-flex items-center` centers the arrow beside the
           whole wrapped block):

               ✅  <.cta_link navigate={~p"/packs"}>Browse every pack</.cta_link>
               ✅  Read it&nbsp;<.cta_arrow />
               ❌  Read it <.cta_arrow />
               ❌  <.link class="inline-flex items-center gap-1">
                     Read it
                     <.icon name="hero-arrow-right" class="h-3.5 w-3.5" />
                   </.link>

           Offending lines (relative to apps/emisar_web/lib):
           #{Enum.map_join(offenders, "\n", &"  #{&1}")}
           """
  end

  test "a cta_link label is glued to both of its tags" do
    offenders = offending_marketing_matches(@unglued_cta_link_slot)

    assert offenders == [],
           """
           Whitespace inside a `<.cta_link>` slot renders as a breakable space, which
           puts back the break opportunity the component's non-breaking space exists
           to remove.

               ✅  <.cta_link navigate={~p"/use-cases"}>See every use case</.cta_link>
               ❌  <.cta_link navigate={~p"/use-cases"}>
                     See every use case
                   </.cta_link>

           Offending lines (relative to apps/emisar_web/lib):
           #{Enum.map_join(offenders, "\n", &"  #{&1}")}
           """
  end
end
