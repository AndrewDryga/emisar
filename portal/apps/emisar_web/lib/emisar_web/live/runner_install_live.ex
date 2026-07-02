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
  - Subscribe to runner events. When the runner minted from THIS page's
    key registers + connects, flash + navigate back to `/app/runners` so
    they land on the page that proves it worked. A different runner joining
    the account's presence (a reconnect, another host) is NOT this install
    and must not redirect — the join is matched on `bootstrap_auth_key_id`.
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
        {command, key_id} = mint_install_command(socket, base)

        socket
        |> assign(:base_url, base)
        |> assign(:install_command, command)
        |> assign(:install_key_id, key_id)
      else
        assign(socket, base_url: nil, install_command: nil, install_key_id: nil)
      end

    {:ok,
     socket
     |> assign(:page_title, "Connect a runner")
     |> assign(:show_troubleshooting?, false)}
  end

  # A runner joined this account's presence — but only bounce the operator to
  # the list when it's the runner minted from THIS page's key. Any OTHER runner
  # joining (a reconnect, another host coming up) is not this operator's install
  # and must not hijack the page. We check the joined runner's `bootstrap_auth_key_id`
  # against the key we minted; a leaving/flapping runner never matches (joins only).
  def handle_info(%{event: "presence_diff", payload: %{joins: joins}}, socket)
      when map_size(joins) > 0 do
    account = socket.assigns.current_account

    if socket.assigns.install_key_id &&
         Runners.any_runner_bootstrapped_by_key?(
           Map.keys(joins),
           socket.assigns.install_key_id,
           account.id
         ) do
      {:noreply,
       socket
       |> put_flash(:info, "Runner connected — taking you to the list.")
       |> push_navigate(to: ~p"/app/#{account}/runners")}
    else
      {:noreply, socket}
    end
  end

  # The grace period elapsed with no runner — surface the troubleshooting
  # checklist (the presence-join navigate above pre-empts this when it works).
  def handle_info(:reveal_troubleshooting, socket),
    do: {:noreply, assign(socket, :show_troubleshooting?, true)}

  def handle_info(_, socket), do: {:noreply, socket}

  # Returns `{command, key_id}` — the key id lets the presence-join handler
  # redirect ONLY for the runner that registers with this exact key. On mint
  # failure, `{:mint_failed, nil}` (a nil key id can never match a join).
  defp mint_install_command(socket, base) do
    case Runners.mint_install_key(socket.assigns.current_subject) do
      {:ok, raw, key} ->
        # Leading space keeps the key out of shell history under
        # HISTCONTROL=ignorespace / HIST_IGNORE_SPACE.
        command =
          " curl -sSL #{base}/install.sh | sudo EMISAR_AUTH_KEY=#{raw} EMISAR_URL=#{base} bash"

        {command, key.id}

      {:error, _} ->
        {:mint_failed, nil}
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
      <:title>
        <.back_link navigate={~p"/app/#{@current_account}/runners"}>Runners</.back_link>
        Connect a runner
      </:title>

      <.install_wizard
        install_command={@install_command}
        base_url={@base_url}
        show_troubleshooting={@show_troubleshooting?}
        on_failure_path={~p"/app/#{@current_account}/settings/runners/auth-keys"}
      />

      <%!-- Follow-up resources, not part of the guided step — siblings
           below the wizard, outside its surface. --%>
      <div class="mt-6 grid grid-cols-1 gap-4 sm:grid-cols-2">
        <.link_card href="/docs/quickstart" icon="hero-book-open" title="Installation guide">
          Image-bake, cloud-init, manual install.
        </.link_card>
        <.link_card navigate="/packs" icon="hero-cube-transparent" title="Pack registry">
          Browse linux-core, cassandra, showcase. Install snippets included.
        </.link_card>
      </div>
    </.dashboard_shell>
    """
  end
end
