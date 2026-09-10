defmodule Emisar.Mailers.Style do
  @moduledoc """
  Shared colors, font stack, inbox-preview padding, and the document shell for
  HTML email. The two HTML mailers had each hand-written the shell and the
  masthead, and the masthead had already drifted by one property.
  """
  alias Emisar.Mailers.HTML
  alias Emisar.PublicUrl

  def ground, do: "#09090b"
  def surface, do: "#111114"
  def hairline, do: "#27272a"
  def ink, do: "#fafafa"
  def ink_soft, do: "#a1a1aa"
  def brand, do: "#8df0ca"
  def rose, do: "#fda4af"
  def amber, do: "#fddf7f"

  def font,
    do: "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif"

  def preview_pad, do: String.duplicate("&#847;&zwnj;&nbsp;", 40)

  @doc """
  The whole HTML document around a mailer's rows: dark-scheme head, the hidden
  inbox-preview line, the full-width ground table, and one centered column of
  `max_width` pixels holding `rows` (already-rendered `<tr>` markup).

  Mail clients are not browsers: no stylesheet, no flexbox, spacing only as
  `<td>` padding. The `color-scheme` meta and style tell a client that would
  otherwise force its own dark mode that the colors are already handled.
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
      </head>
      <body style="margin:0;padding:0;background-color:#{ground()};">
        <div style="display:none;max-height:0;overflow:hidden;mso-hide:all;">#{HTML.escape(preview)}#{preview_pad()}</div>
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#{ground()};">
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
  The logo row. The lockup carries its own dark ground (SVG doesn't render in
  Gmail), because a client that force-inverts the email cannot invert an image
  with it — a transparent white-ink logo would be white ink on a white ground.
  The alt text is styled so a client with images blocked still shows the
  wordmark.
  """
  def masthead do
    """
    <tr>
      <td style="padding:0 0 20px;">
        <img src="#{PublicUrl.url("/images/brand/emisar-email-logo.png")}" width="166" height="50" alt="emisar" style="display:block;border:0;outline:none;text-decoration:none;width:166px;height:50px;font-family:#{font()};font-size:19px;font-weight:600;letter-spacing:-0.01em;color:#{ink()};" />
      </td>
    </tr>
    """
  end
end
