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
  - Same install command + links as the runners-list empty-state wizard
    (an empty fleet drops straight into it), kept in sync via the shared
    `EmisarWeb.RunnerInstall` helper.
  """
  use EmisarWeb, :live_view
  alias Emisar.Runners
  alias EmisarWeb.RunnerInstall
  alias EmisarWeb.UrlHelpers

  def mount(_params, _session, socket) do
    # Install mints a root-capable key at mount — a role that can't mint got a
    # gutted wizard framing the permanent denial as a retryable failure.
    if Runners.subject_can_install_runners?(socket.assigns.current_subject) do
      mount_install(socket)
    else
      {:ok,
       socket
       |> put_flash(:info, "Connecting a runner needs an operator role or above.")
       |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/runners")}
    end
  end

  defp mount_install(socket) do
    socket =
      if connected?(socket) do
        Runners.subscribe_connections(socket.assigns.current_account.id)
        Process.send_after(self(), :reveal_troubleshooting, RunnerInstall.troubleshoot_after_ms())

        base = UrlHelpers.derive_base_url(socket)
        {command, key_id} = RunnerInstall.mint_command(socket.assigns.current_subject, base)

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
        keys_path={~p"/app/#{@current_account}/runners/keys"}
        show_keys_link={Runners.subject_can_manage_auth_keys?(@current_subject)}
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
