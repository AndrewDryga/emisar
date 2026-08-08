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
