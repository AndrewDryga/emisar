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
  alias Emisar.Runners
  alias EmisarWeb.UrlHelpers

  # A runner usually joins within seconds of running the one-liner. If none
  # has after this grace period, reveal a troubleshooting checklist — the
  # likely funnel failure (wrong/truncated key, :443 firewalled, non-systemd
  # host) is otherwise invisible behind a "waiting" pulse that never ends.
  @troubleshoot_after_ms 35_000

  def mount(_params, _session, socket) do
    socket =
      if connected?(socket) do
        Runners.subscribe_connections(socket.assigns.current_account.id)
        Process.send_after(self(), :reveal_troubleshooting, @troubleshoot_after_ms)

        base = UrlHelpers.derive_base_url(socket)

        socket
        |> assign(:base_url, base)
        |> assign(:install_command, mint_install_command(socket, base))
      else
        assign(socket, base_url: nil, install_command: nil)
      end

    {:ok,
     socket
     |> assign(:page_title, "Install a runner")
     |> assign(:show_troubleshooting?, false)}
  end

  # A runner joined this account's presence (registered + connected) while
  # the page was open — bounce the operator over to the runners list so
  # they see their new host immediately. Only presence *joins* navigate, so
  # a leaving/flapping runner doesn't redirect prematurely.
  def handle_info(%{event: "presence_diff", payload: %{joins: joins}}, socket)
      when map_size(joins) > 0 do
    {:noreply,
     socket
     |> put_flash(:info, "Runner connected — taking you to the list.")
     |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/runners")}
  end

  # The grace period elapsed with no runner — surface the troubleshooting
  # checklist (the presence-join navigate above pre-empts this when it works).
  def handle_info(:reveal_troubleshooting, socket),
    do: {:noreply, assign(socket, :show_troubleshooting?, true)}

  def handle_info(_, socket), do: {:noreply, socket}

  defp mint_install_command(socket, base) do
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
    <.dashboard_shell
      current_subject={@current_subject}
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
      fleet_all_offline?={@fleet_all_offline?}
      no_agents?={@no_agents?}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:runners}
      width={:form}
    >
      <:title>Install a runner</:title>
      <:actions>
        <.button variant="secondary" size="md" navigate={~p"/app/#{@current_account}/runners"}>
          ← Back to runners
        </.button>
      </:actions>

      <.install_wizard
        install_command={@install_command}
        base_url={@base_url}
        show_troubleshooting={@show_troubleshooting?}
        on_failure_path={~p"/app/#{@current_account}/settings/runners/auth-keys"}
      />
    </.dashboard_shell>
    """
  end
end
