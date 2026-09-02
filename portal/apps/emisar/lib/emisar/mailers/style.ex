defmodule Emisar.Mailers.Style do
  @moduledoc """
  The visual constants both email bodies are built from: the palette, the ways a
  surface and a rule are drawn, the font stack, and the inbox-snippet padding.

  ## Why this palette looks nothing like the console's

  The Gmail apps rewrite every color an email authors, flipping its HSL lightness.
  They ignore `color-scheme`, ignore `prefers-color-scheme`, and offer no way out
  — Litmus files them under *full color inversion*, the behavior that turns a
  dark-designed email light. Six probe emails through a real account confirmed it
  and pinned down the two rules that matter:

    * A **background** drawn with a gradient or an image is never rewritten.
    * **Text is always rewritten**, whatever it sits on. A dark ground under white
      ink therefore delivers near-black ink on a dark page, and lying about the
      background so the rewrite lands on dark does not change it either.

  So every surface here is painted with `fill/1` rather than `background-color`,
  which freezes the email dark in every client, and every text tone sits at 50%
  HSL lightness — the one value a lightness flip cannot move. That is the whole
  design, and it costs exactly one thing: at 50% lightness a neutral tops out at
  `#808080`, so `ink/0` is the *only* neutral there is. Headings, counts, body and
  captions all wear it, and hierarchy comes from size and weight. Saturated hues
  are unharmed — they read 12:1 and 15:1 — which is why the accents carry more
  weight here than they do in the console.

  Two consequences worth naming before someone "fixes" them:

    * A border is not a background and cannot be frozen, so there are none. Rules
      are `rule/0` rows and cards are `fill/1` inside `fill/1`, one pixel apart.
    * The primary button is tonal. A solid emerald fill cannot work: its label
      flips off it in whichever mode it was not authored for, at 1.4:1.

  `Emisar.Mailers.StyleTest` holds every tone to both readings.
  """

  @doc "The page ground."
  def ground, do: "#09090b"

  @doc "A card or quoted-block ground, one step up from the page."
  def surface, do: "#111114"

  @doc "Rules and card edges — a separator, deliberately below text contrast."
  def hairline, do: "#27272a"

  @doc "Every neutral: headings, counts, body copy, captions. There is only one."
  def ink, do: "#808080"

  @doc "Links, section eyebrows, bullets, passing counts, and the button label."
  def brand, do: "#00ffa1"

  @doc "Failed or denied."
  def rose, do: "#ff0020"

  @doc "Waiting on a human."
  def amber, do: "#ffc300"

  @doc "The primary button's ground — dark, so its brand-colored label carries it."
  def button_fill, do: "#0d3a2a"

  @doc """
  A frozen background, for use anywhere `background-color` would have gone.

  A gradient is the only fill a rewriting client leaves alone. Outlook cannot
  render one, which is what `mso_fallback/1` is for.
  """
  def fill(color), do: "background-image:linear-gradient(#{color},#{color});"

  @doc """
  A frozen one-pixel rule row, standing in for the border that cannot be frozen.

  `colspan` matches the table it is dropped into.
  """
  def rule(colspan \\ 1) do
    ~s(<tr><td colspan="#{colspan}" height="1" style="#{fill(hairline())}height:1px;line-height:1px;font-size:0;">&nbsp;</td></tr>)
  end

  @doc """
  Opens and closes a wrapper that paints the ground for Outlook alone.

  Outlook renders no gradient and would otherwise show this email on white. The
  fallback has to hide inside an mso conditional rather than ride along as a
  `background-color`, because Gmail reads that and rewrites it.
  """
  def mso_fallback(:open) do
    ~s(<!--[if mso]><table role="presentation" width="100%" cellpadding="0" ) <>
      ~s(cellspacing="0" border="0" bgcolor="#{ground()}"><tr><td><![endif]-->)
  end

  def mso_fallback(:close), do: "<!--[if mso]></td></tr></table><![endif]-->"

  @doc "The system stack — Inter is the product face, but no mail client has it."
  def font, do: "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif"

  @doc """
  Padding for the hidden preview line, so a client that pads the inbox snippet
  from the body pulls in nothing instead of the masthead's alt text.
  """
  def preview_pad, do: String.duplicate("&#847;&zwnj;&nbsp;", 40)
end
