defmodule EmisarWeb.Icons do
  @moduledoc """
  The canonical semantic icon registry — the only production icon lookup surface.

  Product code asks for a meaning (`"product.runner"`, `"action.retry"`,
  `"state.offline"`), never a drawing. The masters live beside this module in
  `priv/icons/<namespace>/<name>.svg`, editable in any vector tool and compiled
  in here, so a geometry correction is an ordinary file edit that recompiles.

  A token may carry a second master at `<name>.16.svg`. That is an optical
  variant of the same drawing, not another icon: it exists only where the 16 px
  raster loses a gap, a center, or a modifier.

  Every master is drawn on a centered 24-unit grid. Stroke weight and optical
  projection belong to the output size rather than the file: `grid/1` reports
  the bucket, `CoreComponents.icon_viewbox/1` zooms the small buckets slightly,
  and `assets/css/app.css` sets the weight so the on-screen stroke stays
  ≈1.55–1.65 px at every size instead of thinning as the box shrinks. Anatomy
  paints in `currentColor`; the `accent`, `warn`, `danger`, and `selection`
  classes recolor emphasis without ever being the only carrier of meaning.

  Where the review artwork cleared a gap by painting over it in the review
  page's own surface color, the master carries a real mask instead: the gap is
  transparent, so it stays correct on every surface the product actually has.
  A master file keeps its own `<defs>` so it stays a valid standalone document
  to open and edit, but the page carries one copy of each mask — `mask_defs/0`,
  rendered once by the root layout — because an id repeated per instance is a
  duplicate id, and LiveView patches the DOM by id. Those ids are
  content-addressed, so two different masks can never collide and the same mask
  reached from two icons is provably the same mask.
  """

  @icons_root Path.expand("../../priv/icons", __DIR__)

  # `@external_resource` below re-registers this module when a KNOWN master
  # changes, but a brand-new file changes no watched content, so `mix compile`
  # would keep the stale beam and the new meaning would raise as unknown until
  # a full rebuild. Recompile whenever the LISTING changes.
  @icons_listing @icons_root |> Path.join("*/*.svg") |> Path.wildcard() |> Enum.sort()

  def __mix_recompile__? do
    @icons_root |> Path.join("*/*.svg") |> Path.wildcard() |> Enum.sort() != @icons_listing
  end

  masters =
    Enum.map(@icons_listing, fn path ->
      namespace = path |> Path.dirname() |> Path.basename()
      [name | compact] = path |> Path.basename(".svg") |> String.split(".")

      document =
        case Regex.run(~r/<svg[^>]*>([\s\S]*)<\/svg>/, File.read!(path), capture: :all_but_first) do
          [document] -> String.trim(document)
          nil -> raise "#{path} is not a single <svg> document"
        end

      {defs, body} =
        case Regex.run(~r/^<defs>([\s\S]*)<\/defs>([\s\S]*)$/, document, capture: :all_but_first) do
          [defs, body] -> {String.trim(defs), String.trim(body)}
          nil -> {nil, document}
        end

      {{"#{namespace}.#{name}", compact == ["16"]}, {path, body, defs}}
    end)

  for {_key, {path, _body, _defs}} <- masters, do: @external_resource(path)

  # Marked safe at COMPILE time from files in this repository — never from
  # runner, LLM, or operator input — so a template renders `master/2` directly
  # and no call site reaches for `raw/1` on a variable (IL-16).
  @regular Map.new(masters, fn {{token, compact?}, {_path, body, _defs}} ->
             {{token, compact?}, {:safe, body}}
           end)

  @tokens masters |> Enum.map(fn {{token, _compact?}, _master} -> token end) |> Enum.uniq()

  @mask_defs masters
             |> Enum.map(fn {_key, {_path, _body, defs}} -> defs end)
             |> Enum.reject(&is_nil/1)
             |> Enum.uniq()
             |> Enum.sort()
             |> Enum.join()
             |> then(&{:safe, &1})

  @doc """
  Returns the SVG body for `token` drawn at `size` pixels.

  Raises when the token is unknown: an icon that silently renders nothing is
  how a missing glyph ships invisible.
  """
  @spec master(String.t(), pos_integer()) :: Phoenix.HTML.safe()
  def master(token, size) when is_binary(token) and is_integer(size) do
    compact = Map.get(@regular, {token, true})

    cond do
      size <= 16 and compact -> compact
      body = Map.get(@regular, {token, false}) -> body
      true -> raise ArgumentError, unknown_token_message(token)
    end
  end

  @doc """
  Returns the 24-unit grid bucket whose stroke weight suits `size` pixels.
  """
  @spec grid(pos_integer()) :: 16 | 20 | 24
  def grid(size) when size <= 16, do: 16
  def grid(size) when size <= 20, do: 20
  def grid(_size), do: 24

  @doc """
  Every mask a master references, defined once for the page to share.

  The root layout renders these; an icon whose gap is a real mask resolves its
  reference here rather than carrying its own copy into every instance.
  """
  @spec mask_defs() :: Phoenix.HTML.safe()
  def mask_defs, do: @mask_defs

  @doc "Every semantic token in the registry, sorted."
  @spec tokens() :: [String.t()]
  def tokens, do: @tokens

  @doc "Whether `token` names a registered meaning."
  @spec token?(String.t()) :: boolean()
  def token?(token) when is_binary(token), do: Map.has_key?(@regular, {token, false})
  def token?(_token), do: false

  @doc "Tokens that carry a dedicated 16 px optical master."
  @spec compact_tokens() :: [String.t()]
  def compact_tokens do
    for {{token, true}, _body} <- @regular, do: token
  end

  defp unknown_token_message(token) do
    suggestions =
      @tokens
      |> Enum.sort_by(&String.jaro_distance(&1, token), :desc)
      |> Enum.take(3)
      |> Enum.map_join(", ", &inspect/1)

    "unknown icon #{inspect(token)}. Icons name a meaning from the registry, " <>
      "never a drawing. Closest registered meanings: #{suggestions}. " <>
      "Add a master under priv/icons/ when the meaning is genuinely new."
  end
end
