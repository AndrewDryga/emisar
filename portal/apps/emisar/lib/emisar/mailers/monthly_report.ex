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
  alias Emisar.Mailers.Style
  alias Emisar.PublicUrl
  alias Emisar.Users

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

  # Five, because the approvals split has five outcomes. The runs split has four
  # and leaves its last track empty on purpose — a shared grid is worth more than
  # a filled row, and the two splits align column for column because of it.
  @stat_tracks 5
  @track_width trunc(100 / @stat_tracks)

  @preview_pad Style.preview_pad()

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
      #{number(runs.total)} #{run_label(runs.total)} recorded
      #{runs_caption(runs)}

    #{text_rows([{"Succeeded", runs.success}, {"Failed", runs.failed}, {"Denied", runs.denied}, {"Cancelled", runs.cancelled}])}\
    """
  end

  # Nothing was gated this month — three zeros would read as a broken report.
  defp text_approvals(%{requested: 0}), do: nil

  defp text_approvals(approvals) do
    """
    APPROVALS
      #{number(approvals.requested)} held for a human decision

    #{text_rows([{"Approved", approvals.approved}, {"Denied", approvals.denied}, {"Expired", approvals.expired}, {"Cancelled", approvals.cancelled}, {"Waiting", approvals.pending}])}\
    """
  end

  defp text_right_now(content) do
    rows = [
      {"Active runners", content.runners},
      {"Team members", content.team_size},
      {"Approvals waiting", content.approvals.waiting_now}
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
      "#{number(runs.total)} #{run_label(runs.total)} · #{number(runs.success)} succeeded · #{number(runs.failed)} failed"

    ~s(<div style="display:none;max-height:0;overflow:hidden;mso-hide:all;">#{HTML.escape(text)}#{@preview_pad}</div>)
  end

  # The lockup carries its own dark ground (SVG doesn't render in Gmail), because
  # a client that force-inverts the email cannot invert an image with it — a
  # transparent white-ink logo would be white ink on a white ground. The alt text
  # is styled so a client with images blocked still shows the wordmark.
  defp masthead do
    """
    <tr>
      <td style="padding:0 0 20px;">
        <img src="#{PublicUrl.url("/images/brand/emisar-email-logo.png")}" width="166" height="50" alt="emisar" style="display:block;border:0;outline:none;text-decoration:none;width:166px;height:50px;font-family:#{@font};font-size:19px;font-weight:600;letter-spacing:-0.01em;color:#{@ink};" />
      </td>
    </tr>
    """
  end

  defp heading(content) do
    """
    <tr>
      <td style="padding:0 0 14px;font-family:#{@font};font-size:15px;line-height:1.6;color:#{@ink_soft};">Hi #{HTML.escape(content.recipient)},</td>
    </tr>
    <tr>
      <td style="padding:0 0 28px;font-family:#{@font};font-size:15px;line-height:1.6;color:#{@ink_soft};">Here's what you and your agents ran through emisar for <strong style="font-weight:600;color:#{@ink};">#{HTML.escape(content.account_name)}</strong> in #{HTML.escape(content.period)}.</td>
    </tr>
    """
  end

  # The outcome labels mirror `EmisarWeb.RunStatuses`, the glossary the console
  # and /docs/runs share — the domain app cannot call into the web app, so they
  # are spelled out here. `Denied` is that glossary's word; the card heading is
  # what separates it from the approvals card's own `Denied`.
  defp runs_card(runs) do
    stats = [
      {"Succeeded", runs.success, @brand},
      {"Failed", runs.failed, @rose},
      {"Denied", runs.denied, @rose},
      {"Cancelled", runs.cancelled, @ink_soft}
    ]

    card("Runs", number(runs.total), runs_caption(runs), stats)
  end

  # Nothing was gated this month — three zeros would read as a broken report.
  defp approvals_card(%{requested: 0}), do: ""

  defp approvals_card(approvals) do
    stats = [
      {"Approved", approvals.approved, @brand},
      {"Denied", approvals.denied, @rose},
      {"Expired", approvals.expired, @amber},
      {"Cancelled", approvals.cancelled, @ink_soft},
      {"Waiting", approvals.pending, @amber}
    ]

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
  # a label that wraps on a narrow screen only makes the label row taller. A card
  # with fewer outcomes than `@stat_tracks` pads rather than widening, which is
  # what keeps the two splits on one grid.
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

  defp count_color(0, _color), do: @ink_soft
  defp count_color(_count, color), do: color

  # Current posture, not period activity — a quieter label/value list rather
  # than a third island competing with the two above it.
  defp right_now(content) do
    rows = [
      {"Active runners", content.runners, @ink},
      {"Team members", content.team_size, @ink},
      {"Approvals waiting", content.approvals.waiting_now,
       waiting_color(content.approvals.waiting_now)}
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
            <td bgcolor="#{@button_fill}" style="border-radius:8px;">
              <a href="#{HTML.escape(dashboard_url)}" style="display:inline-block;padding:13px 22px;font-family:#{@font};font-size:14px;line-height:1;font-weight:600;color:#{@ink};text-decoration:none;border-radius:8px;">Open your dashboard</a>
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
        <a href="#{HTML.escape(content.unsubscribe_url)}" style="color:#{@brand};text-decoration:underline;">Unsubscribe</a>
      </td>
    </tr>
    """
  end

  # -- Formatting ----------------------------------------------------------

  defp runs_caption(%{dispatched: 0}), do: "No work was dispatched to a runner."

  defp runs_caption(%{dispatched: dispatched, distinct_runners: 1}),
    do: "#{number(dispatched)} dispatched to 1 runner."

  defp runs_caption(%{dispatched: dispatched, distinct_runners: runners}),
    do: "#{number(dispatched)} dispatched across #{number(runners)} runners."

  defp run_label(1), do: "run"
  defp run_label(_count), do: "runs"

  # Thousands separators, right to left, so a busy fleet reads 12,018 not 12018.
  defp number(count) do
    count
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
