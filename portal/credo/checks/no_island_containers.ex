defmodule Emisar.Checks.NoIslandContainers do
  use Credo.Check,
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      Design-system §8.1: console content sits NAKED on the black canvas — a
      box is earned only by a secret, a code artifact, or an actionable
      warning, and earned boxes come from SHARED components (`code_panel`,
      `secret_reveal`, `output_preview`, `panel` on the settings archetype).
      A live page hand-painting a wash background + frame onto a container
      tag is the "gray island" the console redesign keeps killing.

          # ❌ — an island: wash + frame hand-built in a page template
          <div class="rounded-lg bg-zinc-900/60 p-4 ring-1 ring-white/[0.07]">

          # ✅ — content naked on the canvas; boxes come from shared components
          <div class="divide-y divide-zinc-800/70">
          <.code_panel id="cmd" label="Command" code={@command} />

      Matches a container tag (`div/section/article/ul/ol/li/dl/aside/p`)
      whose opening attributes carry BOTH a wash background
      (`bg-zinc-800/900/950`, `bg-black`, `bg-white` — any opacity;
      `hover:`/`focus:` state washes don't count) AND a frame (`ring-N` or a
      bare full `border`). Buttons, inputs, spans (chips, markers),
      `<pre>`/`<code>` recesses, and shared-component internals never match.

      A deliberate exception — a sanctioned recessed control surface, or a
      hand-built artifact frame pending componentization — is marked with a
      HEEx comment on the line DIRECTLY above the tag (the check reads the
      marker itself; Credo's own disable comments don't reach inside ~H):

          <%!-- credo:disable-for-next-line Emisar.Checks.NoIslandContainers — why --%>
          <div class="…">
      """
    ]

  alias Credo.IssueMeta
  alias Credo.SourceFile

  @container_tag ~r/<(?:div|section|article|ul|ol|li|dl|aside|p)\b/
  @wash ~r/(?<![:\w.-])bg-(?:zinc-(?:800|900|950)|black|white)(?:\/\[?[0-9.]+\]?)?(?![\w-])/
  @frame ~r/(?<![:\w-])(?:ring-[0-9]|border(?![-\w]))/

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if String.contains?(source_file.filename, "apps/emisar_web/lib/emisar_web/live/") do
      issue_meta = IssueMeta.for(source_file, params)
      source = SourceFile.source(source_file)
      lines = String.split(source, "\n")

      @container_tag
      |> Regex.scan(source, return: :index)
      |> Enum.map(fn [{start, _length}] -> {start, line_no(source, start)} end)
      |> Enum.filter(fn {start, _line_no} -> island?(source, start) end)
      |> Enum.reject(fn {_start, line_no} -> disabled?(lines, line_no) end)
      |> Enum.map(fn {_start, line_no} -> issue_for(issue_meta, line_no) end)
    else
      []
    end
  end

  # The tag's opening attributes: from `<tag` to the first `>`. A `>` inside
  # an attribute expression truncates the blob early — that can only
  # under-match (a missed island), never a false positive.
  defp island?(source, start) do
    blob =
      source
      |> binary_part(start, min(2000, byte_size(source) - start))
      |> until_tag_close()

    Regex.match?(@wash, blob) and Regex.match?(@frame, blob)
  end

  defp until_tag_close(slice) do
    case :binary.match(slice, ">") do
      {pos, _length} -> binary_part(slice, 0, pos)
      :nomatch -> slice
    end
  end

  defp line_no(source, start) do
    source |> binary_part(0, start) |> String.split("\n") |> length()
  end

  # Credo's own disable comments are Elixir comments — inside an ~H sigil a
  # `#` line is template text, so the marker is a HEEx comment the check
  # honors itself: the line directly above the flagged tag.
  defp disabled?(lines, line_no) do
    case Enum.at(lines, line_no - 2) do
      nil ->
        false

      previous ->
        String.contains?(previous, "credo:disable-for-next-line") and
          String.contains?(previous, "NoIslandContainers")
    end
  end

  defp issue_for(issue_meta, line_no) do
    format_issue(
      issue_meta,
      message:
        "Hand-painted island: a container tag carries a wash background + frame in a live " <>
          "page. Content sits naked on the canvas (design-system §8.1); an earned box uses a " <>
          "shared component (`code_panel`, `secret_reveal`, `panel`), never inline classes.",
      line_no: line_no
    )
  end
end
