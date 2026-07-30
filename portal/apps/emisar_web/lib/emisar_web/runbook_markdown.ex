defmodule EmisarWeb.RunbookMarkdown do
  @moduledoc """
  Renders the small Markdown subset useful for runbook operator context.

  Headings, paragraphs, ordered and unordered lists, and fenced code blocks
  are structural. Inline HTML is always text, so authoring context cannot
  introduce browser markup, scripts, remote images, or tracking links.
  """
  use Phoenix.Component

  attr :markdown, :string, required: true
  attr :class, :string, default: nil

  def render(assigns) do
    assigns = assign(assigns, :blocks, parse(assigns.markdown))

    ~H"""
    <div class={["space-y-4 text-sm leading-7 text-zinc-300", @class]}>
      <%= for block <- @blocks do %>
        <h3
          :if={block.kind == :heading and block.level <= 2}
          class="pt-1 text-base font-semibold text-zinc-100"
        >
          {block.text}
        </h3>
        <h4
          :if={block.kind == :heading and block.level > 2}
          class="pt-1 text-sm font-semibold text-zinc-100"
        >
          {block.text}
        </h4>
        <p :if={block.kind == :paragraph}>{block.text}</p>
        <ul :if={block.kind == :unordered_list} class="list-disc space-y-1 pl-5 marker:text-zinc-600">
          <li :for={item <- block.items}>{item}</li>
        </ul>
        <ol :if={block.kind == :ordered_list} class="list-decimal space-y-1 pl-5 marker:text-zinc-500">
          <li :for={item <- block.items}>{item}</li>
        </ol>
        <div
          :if={block.kind == :code}
          class="overflow-hidden rounded-xl bg-black/40 ring-1 ring-white/[0.06]"
        >
          <div
            :if={block.language != ""}
            class="border-b border-white/[0.06] px-3 py-1.5 font-mono text-[10px] uppercase tracking-wider text-zinc-500"
          >
            {block.language}
          </div>
          <pre class="overflow-auto p-3 font-mono text-xs leading-6 text-zinc-300"><code>{block.text}</code></pre>
        </div>
      <% end %>
    </div>
    """
  end

  defp parse(markdown) do
    markdown
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> Enum.reduce(initial_state(), &consume_line/2)
    |> finish()
    |> Map.fetch!(:blocks)
    |> Enum.reverse()
  end

  defp initial_state do
    %{blocks: [], paragraph: [], list_kind: nil, list_items: [], code: nil}
  end

  defp consume_line(line, %{code: code} = state) when is_map(code) do
    if String.starts_with?(line, "```") do
      close_code(state)
    else
      put_in(state.code.lines, [line | code.lines])
    end
  end

  defp consume_line(line, state) do
    cond do
      fence = Regex.run(~r/^```([A-Za-z0-9_+-]*)\s*$/, line) ->
        [_, language] = fence
        state |> flush_text() |> Map.put(:code, %{language: language, lines: []})

      String.trim(line) == "" ->
        flush_text(state)

      heading = Regex.run(~r/^(\#{1,4})\s+(.+)$/, line) ->
        [_, marks, text] = heading

        state
        |> flush_text()
        |> push_block(%{kind: :heading, level: String.length(marks), text: text})

      item = Regex.run(~r/^\s*[-*]\s+(.+)$/, line) ->
        [_, text] = item
        append_list_item(state, :unordered_list, text)

      item = Regex.run(~r/^\s*\d+\.\s+(.+)$/, line) ->
        [_, text] = item
        append_list_item(state, :ordered_list, text)

      true ->
        state
        |> flush_list()
        |> Map.update!(:paragraph, &[String.trim(line) | &1])
    end
  end

  defp append_list_item(state, kind, text) do
    state = flush_paragraph(state)

    if state.list_kind in [nil, kind] do
      %{state | list_kind: kind, list_items: [text | state.list_items]}
    else
      state
      |> flush_list()
      |> Map.merge(%{list_kind: kind, list_items: [text]})
    end
  end

  defp finish(%{code: code} = state) when is_map(code), do: close_code(state) |> flush_text()
  defp finish(state), do: flush_text(state)

  defp flush_text(state), do: state |> flush_paragraph() |> flush_list()

  defp flush_paragraph(%{paragraph: []} = state), do: state

  defp flush_paragraph(state) do
    text = state.paragraph |> Enum.reverse() |> Enum.join(" ")

    state
    |> push_block(%{kind: :paragraph, text: text})
    |> Map.put(:paragraph, [])
  end

  defp flush_list(%{list_kind: nil} = state), do: state

  defp flush_list(state) do
    state
    |> push_block(%{kind: state.list_kind, items: Enum.reverse(state.list_items)})
    |> Map.merge(%{list_kind: nil, list_items: []})
  end

  defp close_code(state) do
    block = %{
      kind: :code,
      language: state.code.language,
      text: state.code.lines |> Enum.reverse() |> Enum.join("\n")
    }

    state |> push_block(block) |> Map.put(:code, nil)
  end

  defp push_block(state, block), do: Map.update!(state, :blocks, &[block | &1])
end
