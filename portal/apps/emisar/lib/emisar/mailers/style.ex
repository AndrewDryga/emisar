defmodule Emisar.Mailers.Style do
  @moduledoc """
  The visual constants both email bodies are built from: the palette, the font
  stack, and the inbox-snippet padding.

  ## The email is designed twice, because Gmail redesigns it

  The Gmail apps rewrite every color an email authors, flipping its HSL lightness.
  They ignore `color-scheme`, ignore `prefers-color-scheme`, and offer no way out
  — Litmus files them under *full color inversion*, the behavior that turns a
  dark-designed email light. So this palette is chosen so the rewritten rendering
  is one we designed too: every tone below clears 4.5:1 against its ground as
  authored, and its mirror clears 4.5:1 against the mirrored ground.

  Letting the ground flip along with the text is what keeps the type crisp.
  `ink/0` is near-white on our dark ground and mirrors to near-black on a light
  one — 17:1 either way. The alternative was to freeze the email dark by painting
  every surface with a gradient, which a rewrite skips; it was built and rejected,
  because text can never be frozen, so every tone has to sit at 50% lightness
  where a neutral tops out at 5:1. That made every client worse to fix one.

  ## Why these particular brand steps

  An accent survives the mirror when it is light and not too saturated, which
  moves each one a step up its own scale rather than off-brand:

    * `brand/0` is **brand-200**. brand-400, the logo emerald, mirrors to 1.8:1 —
      unreadable rather than dim, and short of even the 3:1 large-text bar.
    * `amber/0` is **amber-200** for the same reason; amber-300 mirrors to 2.7:1.
    * `rose/0` is **rose-300** unchanged. It is already light and desaturated
      enough to read 10:1 and 12:1.

  The button cannot be the console's: a bright fill under a near-black label reads
  9.8:1 as sent and 1.4:1 mirrored. A deep **brand-800** fill under `ink/0` reads
  6.6:1 and 15.9:1, so it stays a solid emerald button in both renderings.

  An image is never rewritten, which is why the masthead is a lockup with its own
  dark ground baked in rather than the transparent white-ink status logo: on our
  dark ground the chip is invisible, and on a rewritten one it is a brand tile
  instead of white ink on white.

  `Emisar.Mailers.StyleTest` holds every token to both readings.
  """

  @doc "The page ground."
  def ground, do: "#09090b"

  @doc "A card or quoted-block ground, one step up from the page."
  def surface, do: "#111114"

  @doc "Rules and card borders — a separator, deliberately below text contrast."
  def hairline, do: "#27272a"

  @doc "Primary text, and the label on the primary button."
  def ink, do: "#fafafa"

  @doc "Body copy, labels, captions, and a count of zero."
  def ink_soft, do: "#a1a1aa"

  @doc "Links, section eyebrows, bullets, and passing counts — brand-200."
  def brand, do: "#95f3cd"

  @doc "Failed or denied — rose-300, the console's own."
  def rose, do: "#fda4af"

  @doc "Waiting on a human — amber-200."
  def amber, do: "#fde68a"

  @doc "The primary button's fill — brand-800, deep enough to carry `ink/0` both ways."
  def button_fill, do: "#0a6749"

  @doc "The system stack — Inter is the product face, but no mail client has it."
  def font, do: "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif"

  @doc """
  Padding for the hidden preview line, so a client that pads the inbox snippet
  from the body pulls in nothing instead of the masthead's alt text.
  """
  def preview_pad, do: String.duplicate("&#847;&zwnj;&nbsp;", 40)
end
