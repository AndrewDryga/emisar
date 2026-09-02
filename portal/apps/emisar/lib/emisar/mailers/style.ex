defmodule Emisar.Mailers.Style do
  @moduledoc """
  The visual constants both email bodies are built from: the palette, the font
  stack, and the inbox-snippet padding.

  ## The palette has to work upside down

  Gmail's mobile apps ignore `color-scheme` and rewrite every color we author by
  flipping its HSL lightness, keeping hue and saturation. Our dark email is
  therefore delivered to a Gmail dark-mode reader as a *light* one, in a palette
  we never wrote — and any token that only works on a near-black ground fails
  there. So each ink below clears 4.5:1 on both grounds twice: as authored, and
  mirrored. `Emisar.Mailers.StyleTest` holds that line for every token here.

  Two consequences are worth naming, because they read as drift from
  `.agent/kb/rules/design-system.md` and are not:

    * The accents sit lighter than their console counterparts. A console-weight
      `#14cf8d` mirrors to a pale mint, which then swallows the black label of
      the button it fills; `brand/0` is light enough that its mirror is a deep
      green a white label sits on.
    * One emerald covers link, eyebrow, bullet, count, and button fill. The
      button's label is `ground/0`, so its mirrored contrast is the same number
      as mirrored brand-on-ground — one token, one constraint.

  An image is never inverted, which is why the masthead is a lockup with its own
  dark ground baked in rather than the transparent white-ink status logo: on our
  dark ground the chip is invisible, and on Gmail's inverted ground it is a brand
  tile instead of white ink on white.
  """

  @doc "The page ground."
  def ground, do: "#09090b"

  @doc "A card or quoted-block ground, one step up from the page."
  def surface, do: "#111114"

  @doc "Rules and card borders — a separator, deliberately below text contrast."
  def hairline, do: "#27272a"

  @doc "Primary text."
  def ink, do: "#fafafa"

  @doc "Body copy, labels, and captions."
  def ink_soft, do: "#a1a1aa"

  @doc "A count of zero — news about nothing, quiet but still legible."
  def ink_zero, do: "#92929a"

  @doc "Links, section eyebrows, bullets, passing counts, and the button fill."
  def brand, do: "#8df0ca"

  @doc "Failed or denied."
  def rose, do: "#fda4af"

  @doc "Waiting on a human."
  def amber, do: "#fddf7f"

  @doc "The system stack — Inter is the product face, but no mail client has it."
  def font, do: "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif"

  @doc """
  Padding for the hidden preview line, so a client that pads the inbox snippet
  from the body pulls in nothing instead of the masthead's alt text.
  """
  def preview_pad, do: String.duplicate("&#847;&zwnj;&nbsp;", 40)
end
