defmodule Emisar.Runbooks.Naming do
  @moduledoc """
  The one title-to-slug fallback for runbooks.

  The changeset, the console editor, and MCP all accept an optional operator
  slug; this module owns what happens when none was given, so the derivation
  and its column bound are stated once.
  """
  alias Emisar.Slug

  @max_derived_length 79

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

  # `Runbook.Changeset`'s slug format starts with a letter, and a title with no
  # Latin letters or digits slugifies to nothing. A derived slug always passes
  # that format, so an author never sees a slug error for a field left blank:
  # "2FA reset" becomes `rb-2fa-reset` and an all-Cyrillic title `runbook`.
  defp derive_slug(title) do
    case Slug.slugify(title || "", max_length: @max_derived_length) do
      "" ->
        "runbook"

      <<first, _rest::binary>> = slug when first in ?a..?z ->
        slug

      slug ->
        ("rb-" <> slug)
        |> String.slice(0, @max_derived_length)
        |> String.trim_trailing("-")
    end
  end
end
