defmodule EmisarWeb.RunbookVersionsLive do
  @moduledoc """
  Immutable version history of one runbook slug family, newest first. Every
  save is its own version row: each links to the editor for inspection, and
  a published version can be dispatched exactly as saved.

  A row past the family's first also opens what changed against the version
  below it — the question an operator actually arrives with when an agent has
  drafted a revision that a human must publish.
  """
  use EmisarWeb, :live_view
  alias Emisar.{Runbooks, Runs}
  alias EmisarWeb.LiveTable

  def mount(%{"slug" => slug}, _session, socket) do
    if connected?(socket),
      do: Runbooks.subscribe_account_runbooks(socket.assigns.current_account.id)

    {:ok,
     socket
     |> assign(:slug, slug)
     |> assign(:page_title, "Runbook versions")
     |> assign(:open_diffs, MapSet.new())
     |> assign(:diffs, %{})}
  end

  def handle_params(params, _uri, socket) do
    {:noreply, load(socket, params)}
  end

  def handle_event("toggle_diff", %{"id" => id}, socket) do
    if MapSet.member?(socket.assigns.open_diffs, id) do
      {:noreply, update(socket, :open_diffs, &MapSet.delete(&1, id))}
    else
      {:noreply, socket |> update(:open_diffs, &MapSet.put(&1, id)) |> load_diff(id)}
    end
  end

  def handle_info({:list_changed, :runbook, _event_type, _id}, socket),
    do: {:noreply, load(socket, socket.assigns[:page_params] || %{})}

  def handle_info(_, socket), do: {:noreply, socket}

  defp load(socket, params) do
    opts = LiveTable.params_to_opts(params)

    case Runbooks.list_runbook_versions(socket.assigns.slug, socket.assigns.current_subject, opts) do
      # A whole-family count of zero means the slug doesn't resolve for this
      # subject — unknown, deleted, or another account's; all read the same.
      {:ok, _versions, %{count: 0}} ->
        socket
        |> put_flash(:error, "Runbook not found.")
        |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/runbooks")

      {:ok, versions, metadata} ->
        socket
        |> assign(:versions, versions)
        |> assign(:metadata, metadata)
        |> assign(:page_params, params)
        |> assign_live_version()

      # Bad cursor params from a hand-edited URL — retry once, clean.
      {:error, _} when map_size(params) > 0 ->
        load(socket, %{})

      {:error, _} ->
        socket
        |> put_flash(:error, "Runbook not found.")
        |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/runbooks")
    end
  end

  # Every published version here can be dispatched as saved, so the one the
  # console's Run button and execute_runbook resolve by default needs saying.
  defp assign_live_version(socket) do
    case Runbooks.latest_published_by_slugs([socket.assigns.slug], socket.assigns.current_subject) do
      {:ok, published_by_slug} ->
        assign(socket, :live_version, published_by_slug[socket.assigns.slug])

      {:error, _reason} ->
        assign(socket, :live_version, nil)
    end
  end

  # Computed on expansion: most visits open no diff, and each one costs the
  # predecessor row plus a canonical encoding of both definitions.
  defp load_diff(socket, id) do
    case Enum.find(socket.assigns.versions, &(&1.id == id)) do
      nil -> socket
      runbook -> assign_diff(socket, runbook)
    end
  end

  defp assign_diff(socket, runbook) do
    case Runbooks.fetch_previous_version(runbook, socket.assigns.current_subject) do
      {:ok, previous} ->
        diff = Runbooks.definition_diff(previous.definition, runbook.definition)
        update(socket, :diffs, &Map.put(&1, runbook.id, diff))

      {:error, _reason} ->
        put_flash(socket, :error, "Could not load the previous version.")
    end
  end

  defp live_version?(runbook, %{id: id}), do: runbook.id == id
  defp live_version?(_runbook, nil), do: false

  # Unified-diff prefixes, so the change survives being copied out of the
  # browser and reads without relying on colour alone.
  defp diff_line({:ins, text}), do: "+ " <> text
  defp diff_line({:del, text}), do: "- " <> text
  defp diff_line({:eq, text}), do: "  " <> text

  # Deliberate exception to "informative content stays neutral": +/- red-green
  # is the one diff convention every operator already reads, and this IS the
  # decision surface for publishing. Muted tier, and the glyph leads.
  defp diff_line_class({:ins, _text}), do: "bg-brand-500/[0.07] text-brand-300"
  defp diff_line_class({:del, _text}), do: "bg-rose-500/[0.07] text-rose-300"
  defp diff_line_class({:eq, _text}), do: "text-zinc-500"

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_subject={@current_subject}
      current_membership={@current_membership}
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
      fleet_all_offline?={@fleet_all_offline?}
      no_agents?={@no_agents?}
      onboarding_incomplete?={@onboarding_incomplete?}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:runbooks}
      width={:table}
    >
      <:title>
        <.detail_header
          back="Runbooks"
          navigate={~p"/app/#{@current_account}/runbooks"}
          title={@slug}
          mono
        />
      </:title>

      <LiveTable.live_table
        layout={:cards}
        id="runbook-versions"
        path={~p"/app/#{@current_account}/runbooks/#{@slug}/versions"}
        rows={@versions}
        metadata={@metadata}
        wrapper_class="divide-y divide-zinc-800/70"
      >
        <:item :let={runbook}>
          <.list_row padding="py-4">
            <%!-- Every role can inspect the structured definition; the editor
             itself removes mutation controls for viewers. --%>
            <:title>
              <.link
                navigate={~p"/app/#{@current_account}/runbooks/#{runbook.id}/edit"}
                class="truncate font-medium text-zinc-100 hover:text-brand-300"
              >
                {runbook.title}
              </.link>
              <.status_badge status={runbook.status} />
              <span class="font-mono text-[11px] text-zinc-400">v{runbook.version}</span>
              <.chip :if={live_version?(runbook, @live_version)} tone={:brand}>Live</.chip>
            </:title>
            <:meta>
              <.meta_line>
                <:seg>
                  saved{" "}
                  <.local_time
                    id={"runbook-version-#{runbook.id}-saved"}
                    value={runbook.inserted_at}
                    mode={:relative}
                  />
                </:seg>
              </.meta_line>
            </:meta>
            <:actions>
              <%!-- Dispatches this exact immutable version, not the family's
               newest — that's the point of reaching it from history. --%>
              <.button
                :if={
                  runbook.status == :published and
                    Runs.subject_can_dispatch_run?(@current_subject)
                }
                navigate={~p"/app/#{@current_account}/runbooks/#{runbook.id}/run"}
                variant={:secondary}
                size={:sm}
              >
                Run
              </.button>
            </:actions>
            <%!-- v1 opens no disclosure: version numbers are contiguous, so
             only a first version has nothing below it to compare against. --%>
            <:body :if={runbook.version > 1}>
              <.disclosure
                id={"runbook-version-#{runbook.id}-changes"}
                open={MapSet.member?(@open_diffs, runbook.id)}
                summary_click={JS.push("toggle_diff", value: %{id: runbook.id})}
              >
                <:summary>Changes from v{runbook.version - 1}</:summary>
                <.version_diff diff={@diffs[runbook.id]} />
              </.disclosure>
            </:body>
          </.list_row>
        </:item>
        <:empty>No versions on this page.</:empty>
      </LiveTable.live_table>
    </.dashboard_shell>
    """
  end

  attr :diff, :any, required: true

  defp version_diff(%{diff: nil} = assigns) do
    ~H"""
    <p class="text-xs text-zinc-500">Loading…</p>
    """
  end

  defp version_diff(%{diff: %{hunks: []}} = assigns) do
    ~H"""
    <p class="text-xs text-zinc-400">
      The definition is identical. Only the title or description changed.
    </p>
    """
  end

  defp version_diff(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <div :for={{hunk, index} <- Enum.with_index(@diff.hunks)}>
        <div :if={index > 0} class="my-2 border-t border-dashed border-zinc-800"></div>
        <%!-- The JSON indentation is content, so it rides a glued one-line
              `whitespace-pre` span: putting the class on the block would turn
              this template's own newlines into rendered leading whitespace. --%>
        <div
          :for={line <- hunk}
          class={["font-mono text-[11px] leading-5", diff_line_class(line)]}
        >
          <span class="whitespace-pre">{diff_line(line)}</span>
        </div>
      </div>
    </div>
    <p :if={@diff.truncated?} class="mt-3 text-xs text-zinc-400">
      This change is larger than the review shows. Open both versions in the editor for the rest.
    </p>
    """
  end
end
