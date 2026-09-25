defmodule Emisar.Mailers.Style do
  @moduledoc """
  Shared colors, font stack, inbox-preview padding, the document shell and
  masthead for HTML email, and the devices that keep it dark in the Gmail apps.

  The Gmail apps' dark theme flips the HSL lightness of every authored color and
  ignores `color-scheme`, so left alone it turns this email light. Gmail swaps
  the doctype for `<u></u>` and turns `<body>` into a div, so `u + .body` in
  `gmail_css/0` reaches Gmail and nothing else. That block applies in both Gmail
  themes while the flip happens in one, so only self-correcting devices work:
  `fill/1` plus a `gm-` class (Gmail repaints the surface with a gradient, which
  it never flips), `blend/1` for neutral text, accents at 50% lightness (the one
  value a flip leaves alone), and no borders (`rule/1` and `edge/0` are fills).
  `hairline` divides rows; `edge` outlines a container.

  Staying dark in both Gmail themes is a founder requirement, not polish: a
  simplification pass removed these devices once and Gmail turned every email
  light. The measurements are in
  `.agent/kb/rules/design-emails-survive-forced-dark-mode.md`;
  `Emisar.Mailers.StyleTest` holds the line.
  """
  alias Emisar.Mailers.HTML
  alias Emisar.PublicUrl

  def ground, do: "#09090b"
  def surface, do: "#111114"
  def hairline, do: "#27272a"
  def edge, do: "#3f3f46"
  def ink, do: "#fafafa"
  def ink_soft, do: "#a1a1aa"

  @doc "Links, passing counts, success — brand-400's hue at the fixed point."
  def brand, do: "#1ce399"

  @doc """
  Failed or denied — rose-500's hue at the fixed point. At 50% lightness this
  hue is brightest at full saturation, so anything softer drops below 4.5:1 on
  the card.
  """
  def rose, do: "#ff002c"

  @doc "Waiting on a human — amber-400's hue at the fixed point."
  def amber, do: "#fab605"

  @doc """
  The primary button's fill, brand-800. Deep rather than the console's
  brand-500, because its label rides `blend/1` and `screen` is an identity only
  over a dark backdrop: over a bright fill it washes the label into the fill.
  """
  def button_fill, do: "#0a6749"

  def font,
    do: "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif"

  def preview_pad, do: String.duplicate("&#847;&zwnj;&nbsp;", 40)

  @doc "A surface's color. Pair it with the `gm-` class `gmail_css/0` repaints it by."
  def fill(color), do: "background-color:#{color};"

  @doc """
  Wraps `content` so its neutral color survives the rewrite. Spans, so a blended
  run can sit mid-sentence beside an accent, which must stay outside.
  """
  def blend(content) do
    ~s(<span class="gm-screen"><span class="gm-difference">#{content}</span></span>)
  end

  @doc "`blend/1` for text in a neutral `color`; an accent is returned as it is."
  def blend(content, color) do
    if color in [ink(), ink_soft()], do: blend(content), else: content
  end

  @doc "A one-pixel divider row spanning `colspan` cells, drawn as a fill."
  def rule(colspan \\ 1) do
    ~s(<tr><td colspan="#{colspan}" height="1" class="gm-hairline" style="#{fill(hairline())}height:1px;line-height:1px;font-size:0;">&nbsp;</td></tr>)
  end

  @doc """
  The Gmail-only stylesheet; every other client ignores it. Gmail flips the
  blend layers' black to white in the dark theme, and the blend math relies on
  that flip.
  """
  def gmail_css do
    """
    <style>
      u + .body .gm-ground { background-image:linear-gradient(#{ground()},#{ground()}) !important; }
      u + .body .gm-surface { background-image:linear-gradient(#{surface()},#{surface()}) !important; }
      u + .body .gm-hairline { background-image:linear-gradient(#{hairline()},#{hairline()}) !important; }
      u + .body .gm-edge { background-image:linear-gradient(#{edge()},#{edge()}) !important; }
      u + .body .gm-fill { background-image:linear-gradient(#{button_fill()},#{button_fill()}) !important; }
      u + .body .gm-screen { background:#000000; mix-blend-mode:screen; }
      u + .body .gm-difference { background:#000000; mix-blend-mode:difference; }
    </style>
    """
  end

  @doc """
  The whole HTML document around a mailer's rows: dark-scheme head, the Gmail
  block, the hidden inbox-preview line, the full-width ground table, and one
  centered column of `max_width` pixels holding `rows` (already-rendered `<tr>`
  markup).

  Mail clients are not browsers: no flexbox, spacing only as `<td>` padding. The
  `color-scheme` meta and style tell a client that would otherwise force its own
  dark mode that the colors are already handled; the Gmail apps ignore them,
  which is what the `body` class and `gmail_css/0` are for.
  """
  def document(title, preview, max_width, rows) when is_integer(max_width) do
    """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width,initial-scale=1" />
        <meta name="color-scheme" content="dark" />
        <meta name="supported-color-schemes" content="dark" />
        <title>#{HTML.escape(title)}</title>
        <style>:root { color-scheme: dark; supported-color-schemes: dark; }</style>
    #{gmail_css()}  </head>
      <body class="body gm-ground" style="margin:0;padding:0;#{fill(ground())}">
        <div style="display:none;max-height:0;overflow:hidden;mso-hide:all;">#{HTML.escape(preview)}#{preview_pad()}</div>
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" class="gm-ground" style="#{fill(ground())}">
          <tr>
            <td align="center" style="padding:40px 20px;">
              <table role="presentation" align="center" width="#{max_width}" cellpadding="0" cellspacing="0" border="0" style="width:100%;max-width:#{max_width}px;">
                #{rows}
              </table>
            </td>
          </tr>
        </table>
      </body>
    </html>
    """
  end

  @doc """
  The logo row. The lockup is a raster tile with its own dark ground (SVG doesn't
  render in Gmail), because a client that force-inverts the email cannot invert
  an image with it — a transparent white-ink logo would be white ink on a white
  ground. On our ground the tile is invisible; inverted, it is a brand chip.

  The tile pads the mark 4px on the left, 7px on the right, and 6px above and
  below (3x raster: 459x120 for a 153x40 box). The left pad is smaller because
  the chevron's diagonal recedes from the column edge, so the mark reads flush
  with the text beneath it while the chip keeps its air when a client inverts
  the body. The alt text is styled so a client with images blocked still shows
  the wordmark.
  """
  def masthead do
    """
    <tr>
      <td style="padding:0 0 22px;">
        <img src="#{PublicUrl.url("/images/brand/emisar-email-lockup.png")}" width="153" height="40" alt="emisar" style="display:block;border:0;outline:none;text-decoration:none;width:153px;height:40px;font-family:#{font()};font-size:19px;font-weight:600;letter-spacing:-0.01em;color:#{ink()};" />
      </td>
    </tr>
    """
  end
end
