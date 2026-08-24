defmodule EmisarWeb.ContentTicsTest do
  @moduledoc """
  Exact writing tics the founder has corrected, graduated into a tripwire so
  the same shape can never ship twice. Every entry is a phrase that was
  actually corrected on a real page — not a style guess — and each carries the
  correction it came from. Judgment-shaped rules stay in
  `.agent/kb/rules/content-plain-specific-prose.md`; this file holds only
  phrases exact enough to grep with zero false positives on the current site.

  Matching collapses template whitespace first, so a phrase wrapped across
  HEEx lines is still caught.

  Legal pages (terms, privacy, dpa) are excluded — a contract's register
  legitimately says things like "the responsibility is yours".
  """

  use ExUnit.Case, async: true

  @marketing_dir Path.expand(
                   "../../lib/emisar_web/controllers/marketing_html",
                   __DIR__
                 )

  @legal_pages ~w(terms.html.heex privacy.html.heex dpa.html.heex)

  # {phrase, the correction it came from}
  @tics [
    {"is yours",
     "ownership idiom — say what the reader does or keeps (2026-08-22: " <>
       "\"the sign-in is yours either way\"; earlier: \"is yours to edit\")"},
    {"you thought it",
     "aphoristic reveal — state the fact (2026-08-22: \"the authority you " <>
       "thought it did\")"},
    {"is terminal",
     "verdict stamp on delete/revoke — say what the reader loses: \"cannot " <>
       "be restored/undone\" (2026-08-22). Run-lifecycle prose says \"a " <>
       "terminal result/status\", which this phrase does not match."},
    {"changes nothing",
     "negation folded into a pronoun — negate the verb: \"does not change " <>
       "anything\", or name what stays unchanged (2026-08-20)"},
    {"writes nothing", "same negation fold — \"does not write anything\" (2026-08-20)"},
    {"in opposite directions",
     "coined contrast metaphor — state each side's plain fact (2026-08-22: " <>
       "\"they fail in opposite directions\")"},
    {"anything that keeps it", "clever compression for \"anything that stores it\" (2026-08-22)"},
    {"the actor behind",
     "literary tail — say \"who did it\" (2026-08-22: \"the actor behind each\")"},
    {"signs no one out",
     "negation folded into a pronoun — negate the verb: \"does not sign out " <>
       "anyone\" (2026-08-22)"},
    {"is an answer",
     "slogan bullet-title — give the fact and bold the load-bearing phrase " <>
       "inside the sentence instead (2026-08-23: \"An empty page is an answer.\")"},
    {"holds neither",
     "cause compressed into an em-dash punchline — connect it with a plain " <>
       "since-clause: \"since it does not hold a private key\" (2026-08-22: " <>
       "\"it holds neither private key\")"},
    {"Google Workspace proves its tenant",
     "authentication overclaim — say emisar checks the Workspace tenant (2026-08-24)"},
    {"never proves the email address",
     "authentication overclaim — say the claim does not confirm the email address (2026-08-24)"},
    {"proves only the tenant",
     "authentication overclaim — say emisar uses hd to check the Workspace tenant (2026-08-24)"},
    {"proves discovery and reachability",
     "diagnostic overclaim — say Test connection checks discovery and reachability (2026-08-24)"}
  ]

  test "no corrected writing tic reappears on a marketing or docs page" do
    violations =
      @marketing_dir
      |> Path.join("**/*.heex")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, @marketing_dir))
      |> Enum.reject(&(Path.basename(&1) in @legal_pages))
      |> Enum.flat_map(fn file ->
        prose =
          @marketing_dir
          |> Path.join(file)
          |> File.read!()
          |> String.replace(~r/\s+/, " ")

        for {phrase, correction} <- @tics, String.contains?(prose, phrase) do
          "#{file}: \"#{phrase}\" — #{correction}"
        end
      end)

    assert violations == [],
           "Corrected tics found — rewrite the sentence, do not delete the entry:\n" <>
             Enum.join(violations, "\n")
  end
end
