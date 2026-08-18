defmodule Emisar.Mailers.MonthlyReport do
  @moduledoc """
  Renders the monthly account-health report — its subject, its plain-text body,
  and the HTML alternative most operators actually see. Both bodies are built
  from one view model here so the numbers, the wording, and the blocks that
  disappear when they hold nothing can never drift apart.

  The HTML is hand-written tables with fully inline styles because mail clients
  are not browsers: no stylesheet, no flexbox, no SVG, and spacing that Outlook
  honors only as `<td>` padding. It carries the console's dark ground and
  semantic palette (`.agent/kb/rules/design-system.md`) — brand emerald passed,
  rose failed or denied, amber waiting on a human — so the report reads as the
  same product. A count of zero is news about nothing, so it stays muted rather
  than wearing an outcome color.
  """
  alias Emisar.Mailers.HTML
  alias Emisar.PublicUrl
  alias Emisar.Users

  # The console palette, inlined — an email has no Tailwind.
  @ground "#09090b"
  @surface "#111114"
  @hairline "#27272a"
  @ink "#fafafa"
  @ink_soft "#a1a1aa"
  # A zero count: readable at display size, quiet enough to recede.
  @ink_zero "#71717a"
  @brand "#36e6a5"
  @brand_text "#57ecb2"
  @brand_fill "#14cf8d"
  @rose "#fda4af"
  @amber "#fcd34d"

  # Inter is the product face but no mail client has it; the system stack is
  # the closest thing every recipient already has installed.
  @font "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif"

  @stat_tracks 3
  @track_width trunc(100 / @stat_tracks)

  # Zero-width joiners after the preview text, so a client that pads the inbox
  # snippet from the body pulls in nothing instead of the masthead's alt text.
  @preview_pad String.duplicate("&#847;&zwnj;&nbsp;", 40)

  @doc """
  Builds the report email as `%{subject: binary, text: binary, html: binary}`.

  `unsubscribe_url` is minted by the caller, which needs the same URL for the
  `List-Unsubscribe` header.
  """
  def render(%Users.User{} = recipient, account, report, unsubscribe_url) do
    content = %{
      recipient: recipient.full_name || recipient.email,
      account_name: account.name,
      period: Calendar.strftime(report.period_start, "%B %Y"),
      dashboard_url: PublicUrl.url("/app/#{account.slug}"),
      unsubscribe_url: unsubscribe_url,
      runs: report.runs,
      approvals: report.approvals,
      runners: report.runners,
      team_size: report.team_size
    }

    %{
      subject: "Your emisar report for #{content.account_name} — #{content.period}",
      text: text(content),
      html: html(content)
    }
  end

  # -- Plain text ----------------------------------------------------------

  defp text(content) do
    [
      "Hi #{content.recipient},",
      "Here's what you and your agents ran through emisar for #{content.account_name} in #{content.period}.",
      text_runs(content.runs),
      text_approvals(content.approvals),
      text_right_now(content),
      "Open your dashboard:\n  #{content.dashboard_url}",
      "—\nYou're receiving this monthly report as an owner of #{content.account_name}.\nUnsubscribe: #{content.unsubscribe_url}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  defp text_runs(runs) do
    """
    RUNS
      #{number(runs.total)} #{runs_caption(runs.distinct_runners)}

    #{text_rows([{"Succeeded", runs.success}, {"Failed", runs.failed}, {"Denied by policy", runs.denied}])}\
    """
  end

  # Nothing was gated this month — three zeros would read as a broken report.
  defp text_approvals(%{requested: 0}), do: nil

  defp text_approvals(approvals) do
    """
    APPROVALS
      #{number(approvals.requested)} held for a human decision

    #{text_rows([{"Approved", approvals.approved}, {"Denied", approvals.denied}])}\
    """
  end

  defp text_right_now(content) do
    rows = [
      {"Active runners", content.runners},
      {"Team members", content.team_size},
      {"Approvals waiting", content.approvals.pending}
    ]

    "RIGHT NOW\n" <> text_rows(rows)
  end

  # Label/value rows aligned to their own widest label and count, so a block
  # of numbers scans as a column in a monospaced mail client.
  defp text_rows(rows) do
    label_width = rows |> Enum.map(fn {label, _value} -> String.length(label) end) |> Enum.max()

    value_width =
      rows
      |> Enum.map(fn {_label, value} -> value |> number() |> String.length() end)
      |> Enum.max()

    Enum.map_join(rows, "\n", fn {label, value} ->
      "  " <>
        String.pad_trailing(label, label_width) <>
        "  " <> String.pad_leading(number(value), value_width)
    end)
  end

  # -- HTML ----------------------------------------------------------------

  defp html(content) do
    """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width,initial-scale=1" />
        <meta name="color-scheme" content="dark" />
        <meta name="supported-color-schemes" content="dark" />
        <title>#{HTML.escape(content.account_name)} — #{content.period}</title>
        <!-- The report is designed dark; this tells a client that would otherwise force its own dark mode that the colors are already handled. -->
        <style>:root { color-scheme: dark; supported-color-schemes: dark; }</style>
      </head>
      <body style="margin:0;padding:0;background-color:#{@ground};">
        #{preview(content.runs)}
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#{@ground};">
          <tr>
            <td align="center" style="padding:40px 20px;">
              <table role="presentation" align="center" width="600" cellpadding="0" cellspacing="0" border="0" style="width:100%;max-width:600px;">
                #{masthead()}
                #{heading(content)}
                #{runs_card(content.runs)}
                #{approvals_card(content.approvals)}
                #{right_now(content)}
                #{dashboard_button(content.dashboard_url)}
                #{footer(content)}
              </table>
            </td>
          </tr>
        </table>
      </body>
    </html>
    """
  end

  # The inbox snippet — the numbers, before anyone opens anything.
  defp preview(runs) do
    text =
      "#{number(runs.total)} runs · #{number(runs.success)} succeeded · #{number(runs.failed)} failed"

    ~s(<div style="display:none;max-height:0;overflow:hidden;mso-hide:all;">#{HTML.escape(text)}#{@preview_pad}</div>)
  end

  # The transparent white-ink lockup is the only raster logo that sits on a dark
  # ground without a seam (SVG doesn't render in Gmail). The alt text is styled
  # so a client with images blocked still shows the wordmark.
  defp masthead do
    """
    <tr>
      <td style="padding:0 0 30px;">
        <img src="#{PublicUrl.url("/images/brand/emisar-status-logo-dark.png")}" width="138" height="30" alt="emisar" style="display:block;border:0;outline:none;text-decoration:none;width:138px;height:30px;font-family:#{@font};font-size:19px;font-weight:600;letter-spacing:-0.01em;color:#{@ink};" />
      </td>
    </tr>
    """
  end

  defp heading(content) do
    """
    <tr>
      <td style="padding:0 0 10px;font-family:#{@font};font-size:11px;font-weight:600;letter-spacing:0.14em;text-transform:uppercase;color:#{@brand};">Monthly report · #{HTML.escape(content.period)}</td>
    </tr>
    <tr>
      <td style="padding:0 0 14px;font-family:#{@font};font-size:26px;line-height:1.25;font-weight:600;letter-spacing:-0.015em;color:#{@ink};">#{HTML.escape(content.account_name)}</td>
    </tr>
    <tr>
      <td style="padding:0 0 28px;font-family:#{@font};font-size:15px;line-height:1.6;color:#{@ink_soft};">Hi #{HTML.escape(content.recipient)} — here's what you and your agents ran through emisar last month.</td>
    </tr>
    """
  end

  defp runs_card(runs) do
    stats = [
      {"Succeeded", runs.success, @brand_text},
      {"Failed", runs.failed, @rose},
      {"Denied by policy", runs.denied, @rose}
    ]

    card("Runs", number(runs.total), runs_caption(runs.distinct_runners), stats)
  end

  # Nothing was gated this month — three zeros would read as a broken report.
  defp approvals_card(%{requested: 0}), do: ""

  defp approvals_card(approvals) do
    stats = [{"Approved", approvals.approved, @brand_text}, {"Denied", approvals.denied, @rose}]

    card(
      "Approvals",
      number(approvals.requested),
      "held for a human decision",
      stats
    )
  end

  # One island per period fact: an eyebrow, the headline count, and the outcome
  # split under a full-bleed rule.
  defp card(title, headline, caption, stats) do
    """
    <tr>
      <td style="padding:0 0 16px;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#{@surface};border:1px solid #{@hairline};border-radius:12px;">
          <tr>
            <td style="padding:22px 22px 0;font-family:#{@font};font-size:11px;font-weight:600;letter-spacing:0.14em;text-transform:uppercase;color:#{@ink_soft};">#{title}</td>
          </tr>
          <tr>
            <td style="padding:16px 22px 0;font-family:#{@font};font-size:40px;line-height:1;font-weight:600;letter-spacing:-0.03em;color:#{@ink};font-variant-numeric:tabular-nums;">#{headline}</td>
          </tr>
          <tr>
            <td style="padding:10px 22px 20px;font-family:#{@font};font-size:14px;line-height:1.5;color:#{@ink_soft};">#{caption}</td>
          </tr>
          <tr>
            <td style="padding:18px 22px 20px;border-top:1px solid #{@hairline};">#{stat_columns(stats)}</td>
          </tr>
        </table>
      </td>
    </tr>
    """
  end

  # Counts on one row, labels on the next, so every number shares a baseline and
  # a label that wraps on a narrow screen only makes the label row taller. Every
  # card spends the same three tracks, so the approvals split lines up with the
  # runs split above it; a card with fewer stats leaves its last track empty.
  defp stat_columns(stats) do
    tracks = stats ++ List.duplicate(nil, @stat_tracks - length(stats))

    """
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
      <tr>#{Enum.map_join(tracks, &count_cell/1)}</tr>
      <tr>#{Enum.map_join(tracks, &label_cell/1)}</tr>
    </table>
    """
  end

  defp count_cell(nil), do: ~s(<td width="#{@track_width}%"></td>)

  defp count_cell({_label, count, color}) do
    ~s(<td width="#{@track_width}%" style="padding:0 10px 0 0;font-family:#{@font};font-size:24px;line-height:1.1;font-weight:600;letter-spacing:-0.02em;color:#{count_color(count, color)};font-variant-numeric:tabular-nums;">#{number(count)}</td>)
  end

  defp label_cell(nil), do: "<td></td>"

  defp label_cell({label, _count, _color}) do
    ~s(<td style="padding:7px 10px 0 0;font-family:#{@font};font-size:11px;line-height:1.4;letter-spacing:0.08em;text-transform:uppercase;color:#{@ink_soft};">#{label}</td>)
  end

  defp count_color(0, _color), do: @ink_zero
  defp count_color(_count, color), do: color

  # Current posture, not period activity — a quieter label/value list rather
  # than a third island competing with the two above it.
  defp right_now(content) do
    rows = [
      {"Active runners", content.runners, @ink},
      {"Team members", content.team_size, @ink},
      {"Approvals waiting", content.approvals.pending, waiting_color(content.approvals.pending)}
    ]

    """
    <tr>
      <td style="padding:14px 2px 12px;font-family:#{@font};font-size:11px;font-weight:600;letter-spacing:0.14em;text-transform:uppercase;color:#{@ink_soft};">Right now</td>
    </tr>
    <tr>
      <td style="border-bottom:1px solid #{@hairline};">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
          #{Enum.map_join(rows, &posture_row/1)}
        </table>
      </td>
    </tr>
    """
  end

  defp posture_row({label, count, color}) do
    """
    <tr>
      <td style="padding:12px 2px;border-top:1px solid #{@hairline};font-family:#{@font};font-size:14px;color:#{@ink_soft};">#{label}</td>
      <td align="right" style="padding:12px 2px;border-top:1px solid #{@hairline};font-family:#{@font};font-size:14px;font-weight:600;color:#{color};font-variant-numeric:tabular-nums;">#{number(count)}</td>
    </tr>
    """
  end

  # A queue with something in it is waiting on this reader.
  defp waiting_color(0), do: @ink
  defp waiting_color(_pending), do: @amber

  defp dashboard_button(dashboard_url) do
    """
    <tr>
      <td style="padding:30px 0 36px;">
        <table role="presentation" cellpadding="0" cellspacing="0" border="0">
          <tr>
            <td bgcolor="#{@brand_fill}" style="border-radius:8px;">
              <a href="#{HTML.escape(dashboard_url)}" style="display:inline-block;padding:13px 22px;font-family:#{@font};font-size:14px;line-height:1;font-weight:600;color:#{@ground};text-decoration:none;border-radius:8px;">Open your dashboard</a>
            </td>
          </tr>
        </table>
      </td>
    </tr>
    """
  end

  defp footer(content) do
    """
    <tr>
      <td style="padding:22px 0 0;border-top:1px solid #{@hairline};font-family:#{@font};font-size:12px;line-height:1.7;color:#{@ink_soft};">
        You're receiving this monthly report as an owner of #{HTML.escape(content.account_name)}.<br />
        <a href="#{HTML.escape(content.unsubscribe_url)}" style="color:#{@ink_soft};text-decoration:underline;">Unsubscribe</a>
      </td>
    </tr>
    """
  end

  # -- Formatting ----------------------------------------------------------

  # Every run was denied at creation, so none was ever handed to a runner.
  defp runs_caption(0), do: "runs"
  defp runs_caption(1), do: "runs, dispatched to 1 runner"
  defp runs_caption(distinct_runners), do: "runs, dispatched across #{distinct_runners} runners"

  # Thousands separators, right to left, so a busy fleet reads 12,018 not 12018.
  defp number(count) do
    count
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
