defmodule Emisar.Repo.Like do
  @moduledoc """
  Builds `LIKE`/`ILIKE` patterns from user-supplied search terms with the
  wildcard metacharacters escaped, so a typed term matches literally.

  Without escaping, `%`, `_`, and `\\` in a term act as patterns — `a_b` would
  match `axb`, and an all-`%` term would match every row. The patterns are
  parameterized (`^pattern`), so this is never SQL injection — only wrong
  matches — but a search box should still match what the operator typed.

  Two pattern shapes:

    * `contains/1` — `%term%`, a substring search (the "name contains" filters).
    * `prefix/1` — `term%`, an anchored search that keeps a prefix index usable
      (the audit request-id trace).
  """

  @doc "Substring pattern `%term%` with wildcards escaped — for an `ilike`/`like` contains-search."
  def contains(term), do: "%" <> escape(term) <> "%"

  @doc "Anchored prefix pattern `term%` with wildcards escaped — keeps a prefix index usable."
  def prefix(term), do: escape(term) <> "%"

  @doc "Escape LIKE wildcards (`%`, `_`, `\\`) so the term matches literally."
  def escape(term) do
    # Backslash first, so the escapes we add below aren't themselves re-escaped;
    # Postgres LIKE uses `\\` as the default escape character.
    term
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
