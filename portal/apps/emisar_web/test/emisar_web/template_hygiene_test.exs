defmodule EmisarWeb.TemplateHygieneTest do
  @moduledoc """
  Mechanical markup rules over every rendered template in `emisar_web`.

  These live here rather than in `credo/checks/` because **Credo cannot parse
  `.heex`** — it reports the file as unparseable and drops it from the run, so a
  Credo check would only ever see the `~H` sigils embedded in `.ex` files. The
  anchor-glue rule below shipped 8 violations across six files while its grep
  sat documented-but-unrun in `portal/AGENTS.md`; six of those eight were in
  `.heex` files a Credo check could not have reached.

  A rule belongs in this file when it is decidable from the template SOURCE
  TEXT and its subject includes `.heex`. Anything decidable from Elixir AST
  stays a `Emisar.Checks.*` Credo check.
  """
  use ExUnit.Case, async: true

  @web_lib Path.join([__DIR__, "..", "..", "lib"])

  # The HEEx formatter's loose form (`>` ⏎ `text` ⏎ `</.link>.`) leaves the
  # newline + indent INSIDE the anchor, which renders as a visible space before
  # the punctuation — "read the connection guide ." Hand-gluing the text to both
  # tags (`}>text</.link>.`) is what the formatter then preserves.
  @anchor_glue ~r{^\s*</\.?(?:link|a|external_link)>[.,;:!?]}

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

  defp template_sources do
    [
      Path.wildcard(Path.join(@web_lib, "**/*.heex")),
      Path.wildcard(Path.join(@web_lib, "**/*.ex"))
    ]
    |> Enum.concat()
    |> Enum.map(&{Path.relative_to(&1, @web_lib), File.read!(&1)})
  end

  defp offending_lines(pattern) do
    for {file, source} <- template_sources(),
        {line, line_no} <- Enum.with_index(String.split(source, "\n"), 1),
        Regex.match?(pattern, line),
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

  test "inline anchor text is glued to its closing tag when punctuation follows" do
    offenders = offending_lines(@anchor_glue)

    assert offenders == [],
           """
           A closing anchor tag sits on its own line with punctuation after it, so the
           newline + indent render as a visible space before the punctuation ("a shell .").

           Glue the text to both tags — the formatter preserves the adjacency, and a long
           href still wraps in the attribute position:

               ✅  }>read the connection guide</.link>.
               ❌  >
                     read the connection guide
                   </.link>.

           Offending lines (relative to apps/emisar_web/lib):
           #{Enum.map_join(offenders, "\n", &"  #{&1}")}
           """
  end
end
