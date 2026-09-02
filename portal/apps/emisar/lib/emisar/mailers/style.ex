defmodule Emisar.Mailers.Style do
  @moduledoc """
  The visual constants both email bodies are built from, and the three devices
  that keep the design intact in a client that rewrites colors.

  ## What Gmail does, and the one selector that reaches it

  The Gmail apps rewrite every authored color by flipping its HSL lightness. They
  ignore `color-scheme` and `prefers-color-scheme`, and Litmus files them under
  *full color inversion* — the behavior that turns a dark-designed email light.

  But Gmail can be targeted. It replaces the doctype with a `<u></u>` element and
  strips `<body>` into a div, so `u + .body` matches inside Gmail and nowhere
  else; it is the Gmail counterpart of Outlook.com's `[data-ogsc]`. `gmail_css/0`
  is that block, and every other client never sees it. Embedded CSS is dropped
  for non-Google accounts, where the rules simply do not apply and the email
  degrades to Gmail's own rendering.

  Crucially the block applies in **both** Gmail themes while the rewrite happens
  in only one, so no declared color can serve both: naming a color outright is
  right in light mode and wrong in dark, and naming its mirror is exactly the
  reverse. Both were measured. Only self-correcting devices work:

    * **`fill/1`** paints a surface with a gradient, which the rewrite never
      touches. Grounds, card interiors and the button fill hold their color.
    * **`blend/1`** wraps text in Rémi Parmentier's nested `screen` and
      `difference` layers. The math is a no-op when nothing was inverted and
      undoes the inversion when something was — but it returns a hue's
      *complement*, so it carries **achromatic** color only: `ink/0`,
      `ink_soft/0`, and the button's near-black label.
    * A border is not a background and cannot be frozen, so there are none. Rules
      are `rule/1` rows and a card edge is `fill/1` wrapping `fill/1`, a pixel
      apart.

  ## Why the accents sit at 50% lightness

  No blend can carry a hue: they are per-channel RGB operations and the rewrite
  is an HSL lightness flip, so nothing composed of them undoes it for a saturated
  colour. Accents therefore stay outside `blend/1` — and a lightness flip has one
  fixed point, so an accent placed at exactly 50% is its own mirror and does not
  move at all.

  That costs almost nothing here, because it constrains only three colours rather
  than the whole palette: the neutrals carry their own contrast through `blend/1`,
  which is what separates this from flattening the design. Each accent is its
  brand step nudged to that fixed point — six lightness points off brand-400 and
  amber-400, and rose-500 was already close.
  """

  @doc "The page ground."
  def ground, do: "#09090b"

  @doc "A card or quoted-block ground, one step up from the page."
  def surface, do: "#111114"

  @doc "Rules and card edges — a separator, deliberately below text contrast."
  def hairline, do: "#27272a"

  @doc "Primary text. Carried through a rewrite by `blend/1`."
  def ink, do: "#fafafa"

  @doc "Body copy, labels, captions, and a count of zero. Also carried by `blend/1`."
  def ink_soft, do: "#a1a1aa"

  @doc "Links, section eyebrows, bullets, passing counts — brand-400 at its fixed point."
  def brand, do: "#1ce399"

  @doc """
  Failed or denied — rose-500's hue at its fixed point, fully saturated.

  Counter-intuitively the saturation is what buys the contrast: at 50% lightness
  this hue is dullest around 65% saturation and brightest at full, so anything
  softer drops the card reading below 4.5:1.
  """
  def rose, do: "#ff002c"

  @doc "Waiting on a human — amber-400 at its fixed point."
  def amber, do: "#fab605"

  @doc """
  The primary button's fill — brand-800, frozen by `fill/1`.

  Deep rather than the console's brand-500, because the label rides `blend/1` and
  `screen` only behaves as an identity over a dark backdrop. On a bright fill it
  washes a dark label straight into the fill; on this one it leaves `ink/0` alone,
  at 6.6:1, in both renderings.
  """
  def button_fill, do: "#0a6749"

  @doc "The system stack — Inter is the product face, but no mail client has it."
  def font, do: "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif"

  @doc """
  Padding for the hidden preview line, so a client that pads the inbox snippet
  from the body pulls in nothing instead of the masthead's alt text.
  """
  def preview_pad, do: String.duplicate("&#847;&zwnj;&nbsp;", 40)

  @doc "A surface painted so a rewriting client leaves it alone."
  def fill(color), do: "background-color:#{color};"

  @doc "The class that `gmail_css/0` repaints `fill/1` with, keyed by color."
  def fill_class(color) do
    %{ground() => "gm-ground", surface() => "gm-surface", hairline() => "gm-hairline"}
    |> Map.fetch!(color)
  end

  @doc """
  Wraps `content` so its achromatic color survives a rewrite.

  Two nested layers: `difference` restores what the rewrite flipped, `screen`
  puts it back over the surface behind it. Neither does anything in a client that
  never rewrote, so the same markup is correct everywhere.

  They are spans, so a blended run can sit mid-sentence beside an unblended
  accent without breaking the line.
  """
  def blend(content) do
    ~s(<span class="gm-screen"><span class="gm-difference">#{content}</span></span>)
  end

  @doc "A frozen one-pixel rule row, standing in for a border, spanning `colspan`."
  def rule(colspan \\ 1) do
    ~s(<tr><td colspan="#{colspan}" height="1" class="gm-hairline" style="#{fill(hairline())}height:1px;line-height:1px;font-size:0;">&nbsp;</td></tr>)
  end

  @doc "The Gmail-only stylesheet. Every other client ignores it; Gmail cannot rewrite it."
  def gmail_css do
    """
    <style>
      u + .body .gm-ground { background-image:linear-gradient(#{ground()},#{ground()}) !important; }
      u + .body .gm-surface { background-image:linear-gradient(#{surface()},#{surface()}) !important; }
      u + .body .gm-hairline { background-image:linear-gradient(#{hairline()},#{hairline()}) !important; }
      u + .body .gm-fill { background-image:linear-gradient(#{button_fill()},#{button_fill()}) !important; }
      u + .body .gm-screen { background:#000000; mix-blend-mode:screen; }
      u + .body .gm-difference { background:#000000; mix-blend-mode:difference; }
    </style>
    """
  end
end
