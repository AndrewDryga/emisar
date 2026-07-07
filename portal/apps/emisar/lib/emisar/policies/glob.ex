defmodule Emisar.Policies.Glob do
  @moduledoc """
  The policy-override glob grammar, in one tested place. `*` matches any run
  (including empty); every other character is literal. Matching is
  case-insensitive and anchored — the same grammar `Policies.evaluate/3` uses
  to pick the first matching override.

  Pure — no Repo, no Subject (like `Catalog.ActionSetDiff`).
  """

  @doc """
  Whether `string` matches the glob `pattern`. `*` is the only wildcard (any
  run, including empty); all other characters are literal. Anchored and
  case-INSENSITIVE — a deny override like `*.drop_*` must also catch
  `cassandra.DROP_table` (the safe direction for a security matcher), and it
  keeps policy matching consistent with the case-insensitive `ilike` the Runs
  page already uses.
  """
  def match?(pattern, string) do
    matcher = compile(pattern)
    match_compiled?(matcher, string)
  end

  @doc """
  Compiles a policy glob once for repeated matching.

  The policy editor's live outcome preview can test thousands of actions against
  the same override list on every render. Compiling wildcard regexes once per
  preview keeps the matcher semantics identical to `match?/2` without paying
  regex compilation per action.
  """
  def compile(pattern) do
    if String.contains?(pattern, "*") do
      escaped = pattern |> Regex.escape() |> String.replace("\\*", ".*")
      {:regex, Regex.compile!("^" <> escaped <> "$", "i")}
    else
      {:literal, String.downcase(pattern)}
    end
  end

  @doc """
  Matches `string` against a matcher returned by `compile/1`.
  """
  def match_compiled?({:regex, regex}, string), do: Regex.match?(regex, string)

  def match_compiled?({:literal, pattern}, string),
    do: pattern == String.downcase(string)

  @doc """
  Whether glob `a` subsumes glob `b` — i.e. every string matching `b` also
  matches `a` (`L(b) ⊆ L(a)`). The soundness core of shadow detection: a later
  override is dead when an earlier override's glob subsumes it, because
  first-match always picks the earlier one.

  Case-insensitive (globs match case-insensitively). A memoized DP over the
  `{a_index, b_index}` suffix pair, so `*`-heavy operator-authored patterns
  can't blow up exponentially.
  """
  def subsumes?(a, b) when is_binary(a) and is_binary(b) do
    a_chars = a |> String.downcase() |> String.to_charlist() |> List.to_tuple()
    b_chars = b |> String.downcase() |> String.to_charlist() |> List.to_tuple()
    {result, _cache} = sub(a_chars, tuple_size(a_chars), b_chars, tuple_size(b_chars), 0, 0, %{})
    result
  end

  # Memoized DP over suffixes `a[i..]` and `b[j..]`, keyed on `{i, j}` (each
  # recursion only advances i/j forward, so the pair uniquely fingerprints the
  # remaining suffixes). `a`/`b` are char tuples for O(1) indexing.
  defp sub(a, a_len, b, b_len, i, j, cache) do
    key = {i, j}

    case cache do
      %{^key => cached} -> {cached, cache}
      _ -> compute(a, a_len, b, b_len, i, j, cache, key)
    end
  end

  defp compute(a, a_len, b, b_len, i, j, cache, key) do
    cond do
      # A exhausted ⇒ subsumes only if B is also exhausted.
      i == a_len ->
        memo(cache, key, j == b_len)

      # A's '*': matches empty (advance i) OR absorbs one B-unit (advance j).
      elem(a, i) == ?* ->
        {empty?, cache} = sub(a, a_len, b, b_len, i + 1, j, cache)

        cond do
          empty? ->
            memo(cache, key, true)

          # B exhausted ⇒ nothing left for '*' to absorb.
          j == b_len ->
            memo(cache, key, false)

          true ->
            {absorb?, cache} = sub(a, a_len, b, b_len, i, j + 1, cache)
            memo(cache, key, absorb?)
        end

      # A has a leading literal and B is exhausted ⇒ "" ∉ L(A).
      j == b_len ->
        memo(cache, key, false)

      # B's '*' can emit a char ≠ A's literal ⇒ the literal can't cover it.
      elem(b, j) == ?* ->
        memo(cache, key, false)

      # Both literals: they must match and the rest must subsume.
      elem(a, i) == elem(b, j) ->
        {rest?, cache} = sub(a, a_len, b, b_len, i + 1, j + 1, cache)
        memo(cache, key, rest?)

      true ->
        memo(cache, key, false)
    end
  end

  defp memo(cache, key, value), do: {value, Map.put(cache, key, value)}
end
