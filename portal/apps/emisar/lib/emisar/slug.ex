defmodule Emisar.Slug do
  @moduledoc """
  Turns arbitrary text into a URL-safe slug: lowercased, with every run of
  non-alphanumeric characters collapsed to a single hyphen, trimmed of
  leading/trailing hyphens, and capped in length.

  Options:

    * `:max_length` — hard cap on the result length (default #{80})
    * `:default` — value returned when slugification yields an empty string
      (default `""`)
  """
  @default_max_length 80

  def slugify(text, opts \\ []) do
    slug =
      text
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, Keyword.get(opts, :max_length, @default_max_length))

    case slug do
      "" -> Keyword.get(opts, :default, "")
      slug -> slug
    end
  end
end
