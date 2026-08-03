defmodule Emisar.Runbooks.Naming do
  @moduledoc """
  The one title-to-slug fallback for runbooks.

  The changeset, the console editor, and MCP all accept an optional operator
  slug; this module owns what happens when none was given, so the derivation
  and its column bound are stated once.
  """
  alias Emisar.Slug

  @doc """
  Return the operator's slug candidate when it carries a value, otherwise derive
  one from the title.

  A nonblank candidate is returned verbatim — an invalid one is the operator's
  input and belongs in `Runbook.Changeset`'s slug format error, not silently
  replaced here.
  """
  @spec resolve_slug(String.t() | nil, String.t() | nil) :: String.t()
  def resolve_slug(title, candidate) when is_binary(candidate) do
    if String.trim(candidate) == "", do: derive_slug(title), else: candidate
  end

  def resolve_slug(title, _candidate), do: derive_slug(title)

  defp derive_slug(title), do: Slug.slugify(title || "", max_length: 79)
end
