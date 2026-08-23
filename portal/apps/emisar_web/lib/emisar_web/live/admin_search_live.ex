defmodule EmisarWeb.AdminSearchLive do
  @moduledoc """
  Staff account search — the front door of the read-only `/admin` console.

  A blank query lists the most recently created accounts, so a support case
  that starts with "someone just signed up and can't…" opens on the right
  rows. Matching is by account name, slug, or member email; the result cap
  lives in `Emisar.Admin`, so there is nothing to paginate here.
  """
  use EmisarWeb, :live_view
  import EmisarWeb.StaffComponents
  alias Emisar.Admin

  def mount(_params, _session, socket) do
    socket = socket |> assign(:page_title, "Accounts") |> assign(:query, "")

    # IL-18: mount runs twice, so the search only reads on the connected pass.
    if connected?(socket),
      do: {:ok, assign_accounts(socket, "")},
      else: {:ok, assign(socket, :accounts, nil)}
  end

  # The typed value is assigned straight back, so a re-render (a flash, a
  # reconnect) re-serves what the operator typed rather than resetting the box.
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, socket |> assign(:query, query) |> assign_accounts(query)}
  end

  # `Admin.search_accounts/2` re-checks staff on every call (IL-15), so this
  # asserts an invariant the `:ensure_admin` mount gate already holds: a denial
  # here means staff was revoked mid-session, and failing closed drops the
  # socket into a reconnect the gate then turns away.
  defp assign_accounts(socket, query) do
    {:ok, accounts} = Admin.search_accounts(query, socket.assigns.current_user)
    assign(socket, :accounts, accounts)
  end

  # `Admin.search_accounts/2` trims before it decides whether to search or list
  # the newest accounts, so the page's own wording trims too — otherwise a query
  # of spaces gets recent accounts under a "Matching accounts" heading.
  defp blank_query?(query), do: String.trim(query) == ""

  defp results_title(query) do
    if blank_query?(query), do: "Recent accounts", else: "Matching accounts"
  end

  def render(assigns) do
    ~H"""
    <.staff_shell current_user={@current_user}>
      <:title>Accounts</:title>

      <.page_intro>
        Every account on the platform, disabled ones included. Search by account name, slug, or a
        member's email address.
      </.page_intro>

      <%!-- The id is what lets LiveView replay this form after a reconnect, so
           the typed query survives a dropped socket as well as a re-render. --%>
      <form id="account-search" phx-change="search" phx-submit="search">
        <.input
          type="search"
          name="query"
          value={@query}
          label="Search"
          placeholder="acme, acme-corp, or someone@acme.com"
          phx-debounce="300"
          autocomplete="off"
        />
      </form>

      <.loading_state :if={is_nil(@accounts)} />

      <div :if={@accounts}>
        <%!-- Two different facts wear two different states: an empty platform is
             not a search that found nothing, and telling staff to try a slug
             when there is nothing to find sends them hunting for a typo. --%>
        <.empty_state
          :if={@accounts == [] and blank_query?(@query)}
          icon="identity.organization"
          title="No accounts yet."
        >
          Nobody has signed up on this deployment.
        </.empty_state>
        <.empty_state
          :if={@accounts == [] and not blank_query?(@query)}
          icon="action.search"
          title="No accounts match this search."
        >
          Try the account slug, or the email address of someone on the team.
        </.empty_state>

        <div :if={@accounts != []}>
          <.section_header title={results_title(@query)} count={length(@accounts)} />
          <ul class="divide-y divide-zinc-800/70 border-t border-zinc-800/70">
            <.list_row :for={account <- @accounts} id={"account-#{account.id}"} padding="py-4">
              <:title>
                <.link
                  navigate={~p"/admin/accounts/#{account.id}"}
                  class="truncate text-sm font-medium text-zinc-100 transition-colors hover:text-brand-300"
                >
                  {account.name}
                </.link>
              </:title>
              <%!-- Neutral, because that is what `status_badge` already makes
                   "disabled" mean everywhere else; a staff-only rose would be a
                   second vocabulary for one word. --%>
              <:chips>
                <.chip :if={account.disabled_at}>Disabled</.chip>
              </:chips>
              <:meta>
                <.meta_line>
                  <:seg mono>{account.slug}</:seg>
                  <:seg>
                    created{" "}<.local_time
                      id={"account-created-#{account.id}"}
                      value={account.inserted_at}
                      mode={:relative}
                    />
                  </:seg>
                </.meta_line>
              </:meta>
            </.list_row>
          </ul>
        </div>
      </div>
    </.staff_shell>
    """
  end
end
