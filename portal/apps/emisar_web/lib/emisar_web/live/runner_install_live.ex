defmodule EmisarWeb.RunnerInstallLive do
  @moduledoc """
  Install-a-runner wizard. Always available at `/app/runners/install`
  regardless of how many runners are already registered — operators
  adding their second/third/Nth runner need the same experience as
  the first-time onboarding case on the dashboard.

  Behaviour:
  - On mount (connected pass only), mint a fresh install auth key for
    this account so the operator doesn't have to click "generate" then
    copy. Ring eviction in `Runners.mint_install_key/2` caps unused
    autos at 42 per account regardless of how many times this page
    loads.
  - Subscribe to runner events. When a runner registers + connects,
    flash + navigate back to `/app/runners` so they land on the page
    that proves it worked.
  - Same install command shape + same links as the empty-state on the
    dashboard, kept in sync via shared helpers.
  """
  use EmisarWeb, :live_view

  alias Emisar.{PubSub, Runners}
  alias EmisarWeb.UrlHelpers

  def mount(_params, _session, socket) do
    account_id = socket.assigns.current_account.id

    if connected?(socket) do
      PubSub.subscribe_account_runners(account_id)
    end

    install_command =
      if connected?(socket) do
        mint_install_command(socket)
      end

    {:ok,
     socket
     |> assign(:page_title, "Install a runner")
     |> assign(:install_command, install_command)
     |> assign(:waiting?, true)}
  end

  # A runner registered + connected on this account while the page was
  # open — bounce the operator over to the runners list so they see
  # their new host immediately. Filters disconnected events so a flapping
  # runner doesn't redirect prematurely.
  def handle_info({:runner_connected, _runner}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "Runner connected — taking you to the list.")
     |> push_navigate(to: ~p"/app/runners")}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp mint_install_command(socket) do
    base = UrlHelpers.derive_base_url(socket)

    case Runners.mint_install_key(socket.assigns.current_subject) do
      {:ok, raw, _key} ->
        # Leading space keeps the key out of shell history under
        # HISTCONTROL=ignorespace / HIST_IGNORE_SPACE.
        " curl -sSL #{base}/install.sh | sudo EMISAR_AUTH_KEY=#{raw} EMISAR_URL=#{base} bash"

      {:error, _} ->
        :mint_failed
    end
  end

  def render(assigns) do
    ~H"""
    <.dashboard_shell pending_approvals_count={@pending_approvals_count}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:runners}
    >
      <:title>Install a runner</:title>
      <:actions>
        <.link
          navigate={~p"/app/runners"}
          class="rounded-lg border border-zinc-800 px-3 py-1.5 text-sm font-medium text-zinc-300 hover:bg-zinc-900"
        >
          ← Back to runners
        </.link>
      </:actions>

      <.install_wizard
        install_command={@install_command}
        on_failure_path={~p"/app/settings/runners/auth-keys"}
      />
    </.dashboard_shell>
    """
  end
end
