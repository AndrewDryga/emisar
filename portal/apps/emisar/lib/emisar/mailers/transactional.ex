defmodule Emisar.Mailers.Transactional do
  @moduledoc """
  The shared plain-text and HTML frame for short transactional messages.

  Callers supply already-authorized, human copy as a small list of explicit
  blocks. This module owns only presentation: the plain-text structure, escaped
  HTML, preview text, product chrome, and the primary and secondary actions.
  Domain mailers remain responsible for deciding which facts are safe to put
  in durable email.
  """
  alias Emisar.Mailers.HTML
  alias Emisar.Mailers.Style
  alias Emisar.PublicUrl

  @ground Style.ground()
  @surface Style.surface()
  @hairline Style.hairline()
  @ink Style.ink()
  @ink_soft Style.ink_soft()
  @brand Style.brand()
  @rose Style.rose()
  @amber Style.amber()
  @font Style.font()
  @button_fill Style.button_fill()
  @preview_pad Style.preview_pad()

  @type fact_value :: binary() | {:link, binary(), binary()}
  @type block ::
          {:paragraph, binary()}
          | {:link_paragraph, binary(), binary(), binary(), binary()}
          | {:emphasis, binary(), binary(), binary()}
          | {:facts, [{binary(), fact_value()}]}
          | {:status, binary(), binary(), binary(), :success | :warning | :danger | :neutral}
          | {:section, binary()}
          | {:code, binary()}
          | {:pre, binary()}
          | {:list, [binary()]}

  @doc """
  Renders `%{text: binary, html: binary}` from a recipient, title, preview,
  blocks, an optional `{label, url}` primary action, and an optional secondary
  action in the same shape.
  """
  def render(attrs) when is_map(attrs) do
    content = %{
      recipient: Map.fetch!(attrs, :recipient),
      title: Map.fetch!(attrs, :title),
      preview: Map.fetch!(attrs, :preview),
      blocks: Map.get(attrs, :blocks, []),
      action: Map.get(attrs, :action),
      secondary_action: Map.get(attrs, :secondary_action),
      footer: Map.get(attrs, :footer)
    }

    %{text: text(content), html: html(content)}
  end

  defp text(content) do
    blocks =
      content.blocks
      |> Enum.map(&text_block/1)
      |> Enum.reject(&blank?/1)
      |> Enum.join("\n\n")

    [
      "Hi #{content.recipient},",
      blocks,
      text_action(content.action),
      text_action(content.secondary_action),
      content.footer
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  defp text_block({:paragraph, paragraph}), do: paragraph

  defp text_block({:link_paragraph, before, label, url, suffix}),
    do: before <> text_fact_value({:link, label, url}) <> suffix

  defp text_block({:emphasis, before, value, suffix}), do: before <> value <> suffix
  defp text_block({:status, before, status, suffix, _tone}), do: before <> status <> suffix
  defp text_block({:section, title}), do: String.upcase(title)
  defp text_block({:code, code}), do: "    #{code}"
  defp text_block({:pre, value}), do: indent(value)
  defp text_block({:list, items}), do: Enum.map_join(items, "\n", &("  • " <> &1))
  defp text_block({:facts, []}), do: nil

  defp text_block({:facts, facts}) do
    width = facts |> Enum.map(fn {label, _value} -> String.length(label) end) |> Enum.max()

    Enum.map_join(facts, "\n", fn {label, value} ->
      "  #{String.pad_trailing(label <> ":", width + 1)}  #{text_fact_value(value)}"
    end)
  end

  defp text_fact_value({:link, label, url}), do: "#{label} (#{url})"
  defp text_fact_value(value), do: value

  defp text_action(nil), do: nil
  defp text_action({label, url}), do: "#{label}:\n\n#{url}"

  defp html(content) do
    """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width,initial-scale=1" />
        <meta name="color-scheme" content="dark" />
        <meta name="supported-color-schemes" content="dark" />
        <title>#{HTML.escape(content.title)}</title>
        <style>:root { color-scheme: dark; supported-color-schemes: dark; }</style>
      </head>
      <body style="margin:0;padding:0;background-color:#{@ground};">
        <div style="display:none;max-height:0;overflow:hidden;mso-hide:all;">#{HTML.escape(content.preview)}#{@preview_pad}</div>
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#{@ground};">
          <tr>
            <td align="center" style="padding:40px 20px;">
              <table role="presentation" align="center" width="560" cellpadding="0" cellspacing="0" border="0" style="width:100%;max-width:560px;">
                #{masthead()}
                <tr>
                  <td style="padding:0 0 24px;font-family:#{@font};font-size:15px;line-height:1.65;color:#{@ink_soft};">Hi #{HTML.escape(content.recipient)},</td>
                </tr>
                #{Enum.map_join(content.blocks, &html_block/1)}
                #{html_actions(content.action, content.secondary_action)}
                #{html_footer(content.footer)}
              </table>
            </td>
          </tr>
        </table>
      </body>
    </html>
    """
  end

  defp masthead do
    """
    <tr>
      <td style="padding:0 0 20px;">
        <img src="#{PublicUrl.url("/images/brand/emisar-email-logo.png")}" width="166" height="50" alt="emisar" style="display:block;border:0;outline:none;text-decoration:none;width:166px;height:50px;font-family:#{@font};font-size:19px;font-weight:600;color:#{@ink};" />
      </td>
    </tr>
    """
  end

  defp html_block({:paragraph, paragraph}) do
    ~s(<tr><td style="padding:0 0 18px;font-family:#{@font};font-size:15px;line-height:1.65;color:#{@ink_soft};">#{HTML.escape(paragraph)}</td></tr>)
  end

  defp html_block({:link_paragraph, before, label, url, suffix}) do
    ~s(<tr><td style="padding:0 0 18px;font-family:#{@font};font-size:15px;line-height:1.65;color:#{@ink_soft};">#{HTML.escape(before)}<a href="#{HTML.escape(url)}" target="_top" style="color:#{@brand};font-weight:600;text-decoration:underline;text-underline-offset:2px;">#{HTML.escape(label)}</a>#{HTML.escape(suffix)}</td></tr>)
  end

  defp html_block({:emphasis, before, value, suffix}) do
    ~s(<tr><td style="padding:0 0 18px;font-family:#{@font};font-size:15px;line-height:1.65;color:#{@ink_soft};">#{HTML.escape(before)}<strong style="font-weight:700;color:#{@ink};">#{HTML.escape(value)}</strong>#{HTML.escape(suffix)}</td></tr>)
  end

  defp html_block({:status, before, status, suffix, tone}) do
    ~s(<tr><td style="padding:0 0 18px;font-family:#{@font};font-size:15px;line-height:1.65;color:#{@ink_soft};">#{HTML.escape(before)}<strong style="font-weight:700;color:#{status_color(tone)};">#{HTML.escape(status)}</strong>#{HTML.escape(suffix)}</td></tr>)
  end

  defp html_block({:section, title}) do
    ~s(<tr><td style="padding:10px 0 10px;font-family:#{@font};font-size:11px;font-weight:600;letter-spacing:0.14em;text-transform:uppercase;color:#{@brand};">#{HTML.escape(title)}</td></tr>)
  end

  defp html_block({:facts, []}), do: ""

  defp html_block({:code, code}) do
    """
    <tr>
      <td style="padding:0 0 18px;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#{@surface};border:1px solid #{@hairline};border-radius:10px;">
          <tr><td align="center" style="padding:18px 16px;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:24px;line-height:1.1;font-weight:700;letter-spacing:0.16em;color:#{@ink};">#{HTML.escape(code)}</td></tr>
        </table>
      </td>
    </tr>
    """
  end

  defp html_block({:facts, facts}) do
    rows = Enum.map_join(facts, fn {label, value} -> fact_row(label, value) end)

    """
    <tr>
      <td style="padding:0 0 18px;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-top:1px solid #{@hairline};">#{rows}</table>
      </td>
    </tr>
    """
  end

  defp html_block({:pre, value}) do
    ~s(<tr><td style="padding:14px 16px 16px;background-color:#{@surface};border:1px solid #{@hairline};border-radius:10px;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12px;line-height:1.6;white-space:pre-wrap;word-break:break-word;color:#{@ink_soft};">#{HTML.escape(value)}</td></tr><tr><td style="height:18px;"></td></tr>)
  end

  defp html_block({:list, items}) do
    list = Enum.map_join(items, "", &list_item/1)

    ~s(<tr><td style="padding:0 0 18px;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">#{list}</table></td></tr>)
  end

  defp fact_row(label, value) do
    """
    <tr>
      <td valign="top" style="padding:11px 14px 11px 0;border-bottom:1px solid #{@hairline};font-family:#{@font};font-size:13px;line-height:1.5;color:#{@ink_soft};">#{HTML.escape(label)}</td>
      <td valign="top" align="right" style="padding:11px 0;border-bottom:1px solid #{@hairline};font-family:#{@font};font-size:13px;line-height:1.5;font-weight:600;color:#{@ink};">#{html_fact_value(value)}</td>
    </tr>
    """
  end

  defp html_fact_value({:link, label, url}) do
    ~s(<a href="#{HTML.escape(url)}" target="_top" style="color:#{@brand};text-decoration:underline;text-underline-offset:2px;">#{HTML.escape(label)}</a>)
  end

  defp html_fact_value(value), do: HTML.escape(value)

  defp list_item(item) do
    ~s(<tr><td valign="top" width="18" style="padding:3px 0;font-family:#{@font};font-size:15px;line-height:1.55;color:#{@brand};">•</td><td style="padding:3px 0;font-family:#{@font};font-size:14px;line-height:1.55;color:#{@ink_soft};">#{HTML.escape(item)}</td></tr>)
  end

  defp html_actions(nil, nil), do: ""

  defp html_actions(action, secondary_action) do
    actions = [{:primary, action}, {:secondary, secondary_action}]
    buttons = actions |> Enum.reject(fn {_kind, value} -> is_nil(value) end) |> action_cells()

    """
    <tr>
      <td style="padding:8px 0 30px;">
        <table role="presentation" cellpadding="0" cellspacing="0" border="0">
          <tr>#{buttons}</tr>
        </table>
      </td>
    </tr>
    """
  end

  defp action_cells(actions) do
    Enum.map_join(actions, ~s(<td width="10" style="width:10px;"></td>), &action_cell/1)
  end

  defp action_cell({:primary, {label, url}}) do
    ~s(<td bgcolor="#{@button_fill}" style="border-radius:8px;"><a href="#{HTML.escape(url)}" target="_top" style="display:inline-block;padding:13px 22px;font-family:#{@font};font-size:14px;line-height:1;font-weight:600;color:#{@ink};text-decoration:none;border-radius:8px;">#{HTML.escape(label)}</a></td>)
  end

  defp action_cell({:secondary, {label, url}}) do
    ~s(<td style="border:1px solid #{@hairline};border-radius:8px;"><a href="#{HTML.escape(url)}" target="_top" style="display:inline-block;padding:12px 21px;font-family:#{@font};font-size:14px;line-height:1;font-weight:600;color:#{@ink};text-decoration:none;border-radius:8px;">#{HTML.escape(label)}</a></td>)
  end

  defp html_footer(footer) when is_binary(footer) and footer != "" do
    """
    <tr>
      <td style="padding:20px 0 0;border-top:1px solid #{@hairline};font-family:#{@font};font-size:12px;line-height:1.65;color:#{@ink_soft};">#{HTML.escape(footer)}</td>
    </tr>
    """
  end

  defp html_footer(_footer), do: ""

  defp status_color(:success), do: @brand
  defp status_color(:warning), do: @amber
  defp status_color(:danger), do: @rose
  defp status_color(:neutral), do: @ink

  defp indent(value), do: value |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))
  defp blank?(value), do: is_nil(value) or value == ""
end
