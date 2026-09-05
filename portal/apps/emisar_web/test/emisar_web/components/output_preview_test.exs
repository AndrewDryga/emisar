defmodule EmisarWeb.Components.OutputPreviewTest do
  @moduledoc """
  Renders `EmisarWeb.DomainComponents.output_preview/1`, the bounded terminal tail
  used by runbook executions. The command is runner-reported redacted evidence;
  output remains escaped, size-bounded, and keyboard-scrollable.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.DomainComponents

  test "renders the runner-reported command and chronological output in one terminal" do
    assigns = %{
      command: "systemctl --failed --token [REDACTED]",
      events: [
        %{stream: "stdout", payload: %{"chunk" => "unit-a.service\n"}},
        %{stream: "stderr", payload: %{"chunk" => "<unit-b.service>\n"}}
      ]
    }

    html =
      rendered_to_string(~H"""
      <DomainComponents.output_preview
        command={@command}
        command_truncated?
        events={@events}
      />
      """)

    assert html =~ "$ "
    assert html =~ "systemctl --failed --token [REDACTED]"
    assert html =~ " …"
    assert html =~ "unit-a.service"
    assert html =~ "&lt;unit-b.service&gt;"
    assert html =~ "text-rose-300"
    assert html =~ ~s(tabindex="0")
    assert html =~ ~s(aria-label="Command and output")
    assert html =~ "overflow-auto whitespace-pre"
    refute html =~ "rounded-lg"
    refute html =~ "border-zinc-800"
    refute html =~ "bg-zinc-950"
  end

  test "keeps only the newest bounded output and says what was omitted" do
    assigns = %{
      events: [
        %{stream: "stdout", payload: %{"chunk" => "first\n"}},
        %{stream: "stdout", payload: %{"chunk" => "later\n"}}
      ]
    }

    html =
      rendered_to_string(~H|<DomainComponents.output_preview events={@events} max_chars={6} />|)

    refute html =~ "first"
    assert html =~ "earlier output omitted"
    assert html =~ "later"
  end

  test "renders nothing when neither command nor output exists" do
    assigns = %{}

    html = rendered_to_string(~H|<DomainComponents.output_preview events={[]} />|)

    refute html =~ "<pre"
  end

  test "marks database-clipped output even when it fits the display cap" do
    assigns = %{
      events: [
        %{stream: "stderr", payload: %{"chunk" => "🙂 tail"}, preview_truncated?: true}
      ]
    }

    html = rendered_to_string(~H|<DomainComponents.output_preview events={@events} />|)
    assert html =~ "earlier output omitted"
    assert html =~ "🙂 tail"
    assert html =~ "text-rose-300"
  end

  test "keeps the contiguous tail after a clipped chunk without stitching older output across it" do
    assigns = %{
      events: [
        %{stream: "stdout", payload: %{"chunk" => "older output\n"}},
        %{stream: "stderr", payload: %{"chunk" => "🙂 tail\n"}, preview_truncated?: true},
        %{stream: "stdout", payload: %{"chunk" => "newer output\n"}}
      ]
    }

    html = rendered_to_string(~H|<DomainComponents.output_preview events={@events} />|)
    refute html =~ "older output"
    assert html =~ "🙂 tail"
    assert html =~ "newer output"
    assert length(String.split(html, "earlier output omitted")) == 2
  end

  test "shows omission when a byte cap cannot retain a whole code point" do
    assigns = %{
      events: [
        %{stream: "stdout", payload: %{"chunk" => "older output\n"}},
        %{stream: "stderr", payload: %{"chunk" => ""}, preview_truncated?: true}
      ]
    }

    html = rendered_to_string(~H|<DomainComponents.output_preview events={@events} />|)
    assert html =~ "earlier output omitted"
    refute html =~ "older output"
  end
end
