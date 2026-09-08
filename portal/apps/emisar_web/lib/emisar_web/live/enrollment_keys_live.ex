defmodule EmisarWeb.EnrollmentKeysLive do
  use EmisarWeb, :live_view
  alias Emisar.Runners
  alias EmisarWeb.{LiveForm, LiveTable, Permissions, URLHelpers}
  alias Phoenix.LiveView.JS

  def mount(_params, _session, socket) do
    # Manage-only page (enrollment keys have no view-only permission): anyone
    # without manage lands on not-found at LOAD time, not on first submit.
    if Runners.subject_can_manage_enrollment_keys?(socket.assigns.current_subject) do
      # Subscribe to the per-account enrollment-keys topic so another operator's
      # create / revoke (or an auto-bind from a runner registration) reflows
      # this list without the viewer having to refresh.
      if connected?(socket),
        do: Runners.subscribe_account_enrollment_keys(socket.assigns.current_account.id)

      {:ok,
       socket
       |> assign(:page_title, "Enrollment keys")
       |> assign(:new_secret, nil)
       |> assign(:install_command, nil)
       |> assign(:base_url, URLHelpers.derive_base_url(socket))
       # IL-18: only hit the billing read on the connected mount; the
       # cap-warning banner just stays hidden until it loads.
       |> assign(:billing, connected?(socket) && fetch_billing(socket))
       |> assign_form(Runners.change_enrollment_key())}
    else
      {:ok,
       socket
       |> put_flash(:error, "Only owners and admins can manage enrollment keys.")
       |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/runners")}
    end
  end

  # The issue form is refused for a runner-scoped admin at the route, not at the
  # submit: never route an operator into an action that cannot succeed. The
  # domain gate in `create_enrollment_key/2` is still the authorization.
  def handle_params(_params, _uri, %{assigns: %{live_action: :new}} = socket) do
    if Runners.subject_can_create_enrollment_keys?(socket.assigns.current_subject) do
      {:noreply, socket |> assign(:page_title, "Create an enrollment key") |> load(%{})}
    else
      {:noreply,
       socket
       |> put_flash(:error, issue_key_lock_text())
       |> push_patch(to: ~p"/app/#{socket.assigns.current_account}/runners/keys")}
    end
  end

  # IL-18: `handle_params` runs on the dead render too, and the list's empty
  # branch shows `<.loading_state />` there — so the key list plus the two
  # access reads in `load/2` were paid for and thrown away on the first paint,
  # then paid for again on connect. Same shape as runs / runners / audit.
  def handle_params(params, _uri, socket) do
    socket = assign(socket, :page_title, "Enrollment keys")

    if connected?(socket) do
      {:noreply, load(socket, params)}
    else
      {:noreply, prepare_disconnected(socket, params)}
    end
  end

  def handle_info({:list_changed, :enrollment_key, _event_type, _id}, socket),
    do: {:noreply, load(socket, socket.assigns[:filter_params] || %{})}

  def handle_info(_, socket), do: {:noreply, socket}

  # ONE spelling of why key creation is locked — the disabled control's tooltip,
  # the empty state, and the route-guard flash all read from here, so the three
  # cannot drift into three different rules.
  defp issue_key_lock_text do
    "You need access to all runners to create an enrollment key."
  end

  defp fetch_billing(socket) do
    case Emisar.Billing.billing_summary(
           socket.assigns.current_account,
           socket.assigns.current_subject
         ) do
      {:ok, summary} -> summary
      {:error, _} -> nil
    end
  end

  def handle_event("validate", %{"enrollment_key" => params} = event, socket) do
    changeset = Runners.change_enrollment_key(params) |> LiveForm.on_change(event)
    {:noreply, assign_form(socket, changeset)}
  end

  # A crafted event that drops a required key would otherwise match no clause
  # and crash the socket, taking the page's unsaved state with it. Every
  # mutating handler on this page ends in this no-op.
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("create", %{"enrollment_key" => params}, socket) do
    Permissions.gated(
      socket,
      Runners.subject_can_create_enrollment_keys?(socket.assigns.current_subject),
      &do_create(&1, params)
    )
  end

  def handle_event("create", _params, socket), do: {:noreply, socket}

  def handle_event("dismiss_secret", _params, socket) do
    {:noreply,
     socket
     |> assign(:new_secret, nil)
     |> assign(:install_command, nil)}
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    Permissions.gated(
      socket,
      Runners.subject_can_revoke_enrollment_keys?(socket.assigns.current_subject),
      &do_revoke(&1, id)
    )
  end

  def handle_event("revoke", _params, socket), do: {:noreply, socket}

  def handle_event("filter", params, socket) do
    {:noreply,
     LiveTable.apply_filter(
       socket,
       ~p"/app/#{socket.assigns.current_account}/runners/keys",
       params,
       Runners.enrollment_key_filters()
     )}
  end

  def handle_event("restore_source_filter", %{"source" => source}, socket)
      when source in ["", "manual", "console"] do
    # A shared URL or a choice already made on this page wins over browser
    # preferences. The normal filtered read still checks current permissions.
    if socket.assigns.live_action == :index and
         not Map.has_key?(socket.assigns.filter_params, "source") do
      params = socket.assigns.filter_params |> Map.take(["status"]) |> Map.put("source", source)
      handle_event("filter", params, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("restore_source_filter", _params, socket), do: {:noreply, socket}

  defp do_create(socket, params) do
    case Runners.create_enrollment_key(params, socket.assigns.current_subject) do
      {:ok, raw, _key} ->
        install_command =
          case Runners.enrollment_install_command(raw, socket.assigns.base_url) do
            {:ok, command} -> command
            {:error, :insecure_base_url} -> :insecure_transport
            {:error, _reason} -> :unavailable
          end

        # The reveal IS the success step on the /new page — no flash, and no
        # list reload (the list isn't shown here; :index remounts fresh).
        {:noreply,
         socket
         |> assign(:new_secret, raw)
         |> assign(:install_command, install_command)
         |> assign_form(Runners.change_enrollment_key())}

      # Field errors (a rejected value, a DB constraint) render inline on the
      # form, with the operator's own params preserved for redisplay.
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp do_revoke(socket, id) do
    case Enum.find(socket.assigns.enrollment_keys, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      key ->
        case Runners.revoke_enrollment_key(key, socket.assigns.current_subject) do
          {:ok, _} -> {:noreply, socket |> put_flash(:info, "Key revoked.") |> reload()}
          {:error, _} -> {:noreply, socket}
        end
    end
  end

  # Re-runs the current load with whatever filter/page params are
  # already on the URL — so a create or revoke doesn't bounce the
  # operator back to page 1 or wipe their filter.
  defp reload(socket), do: load(socket, socket.assigns[:filter_params] || %{})

  defp prepare_disconnected(socket, params) do
    socket
    |> assign(:enrollment_keys, [])
    |> assign(:metadata, %Emisar.Repo.Paginator.Metadata{count: 0, limit: 0})
    |> assign(:can_create_keys?, false)
    |> assign(:can_revoke_keys?, false)
    |> assign(:filter_params, params)
    |> assign(:filters, Runners.enrollment_key_filters())
    |> assign(:load_error?, false)
  end

  defp load(socket, params) do
    # Unusable keys hide by default via the status filter's `%Filter{default:}` —
    # LiveTable resolves absent → "active" and keeps an explicit "All" in the
    # URL (apply_filter gets the filters below), so no param injection here.
    filters = Runners.enrollment_key_filters()
    opts = LiveTable.params_to_opts(params, filters)

    # Both predicates read the member's current runner access from the database,
    # so they are resolved once per load — never from the template, where the
    # row slot would re-run them for every key on the page. Every navigation and
    # every list change lands here, and the domain re-authorizes at the mutation
    # anyway, so the rendered affordance still tracks a scope narrowed mid-session.
    socket =
      socket
      |> assign(
        :can_create_keys?,
        Runners.subject_can_create_enrollment_keys?(socket.assigns.current_subject)
      )
      |> assign(
        :can_revoke_keys?,
        Runners.subject_can_revoke_enrollment_keys?(socket.assigns.current_subject)
      )

    case Runners.list_enrollment_keys(
           socket.assigns.current_subject,
           Keyword.put(opts, :preload, [:created_by])
         ) do
      {:ok, enrollment_keys, meta} ->
        socket
        |> assign(:enrollment_keys, enrollment_keys)
        |> assign(:metadata, meta)
        |> assign(:filter_params, params)
        |> assign(:filters, filters)
        |> assign(:load_error?, false)

      # A clean reload can fail too (e.g. the subject can't list keys) —
      # degrade to an empty list rather than recursing forever. Flag it: this is
      # the page that gates fleet onboarding, and rendering a denied read as
      # "no enrollment keys yet" tells an operator the opposite of the truth.
      {:error, _} when map_size(params) == 0 ->
        socket
        |> assign(:enrollment_keys, [])
        |> assign(:metadata, %Emisar.Repo.Paginator.Metadata{count: 0, limit: 0})
        |> assign(:filter_params, params)
        |> assign(:filters, filters)
        |> assign(:load_error?, true)

      # Bad filter/page params from a hand-edited URL — retry once, clean.
      {:error, _} ->
        load(socket, %{})
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset, as: "enrollment_key"))
  end

  defp truthy?("true"), do: true
  defp truthy?(true), do: true
  defp truthy?("on"), do: true
  defp truthy?(_), do: false

  defp key_usage(key) do
    limit = if key.reusable, do: key.max_uses, else: 1

    if limit do
      "#{key.uses_count}/#{limit} uses"
    else
      "#{key.uses_count} #{if key.uses_count == 1, do: "use", else: "uses"}"
    end
  end

  def render(assigns) do
    ~H"""
    <.console_shell
      chrome={@shell_chrome}
      current_membership={@current_membership}
      current_subject={@current_subject}
      current_user={@current_user}
      current_account={@current_account}
      section={:runners}
      width={:table}
    >
      <:title>
        <%= if @live_action == :new do %>
          <.back_link navigate={~p"/app/#{@current_account}/runners"}>Runners</.back_link>
          <.back_link navigate={~p"/app/#{@current_account}/runners/keys"}>
            Enrollment keys
          </.back_link>
          Create an enrollment key
        <% else %>
          <.back_link navigate={~p"/app/#{@current_account}/runners"}>Runners</.back_link>
          Enrollment keys
        <% end %>
      </:title>
      <:actions :if={@live_action == :index}>
        <%= if @can_create_keys? do %>
          <.button
            navigate={~p"/app/#{@current_account}/runners/keys/new"}
            size={:md}
            icon="action.add"
          >
            New key
          </.button>
        <% else %>
          <%!-- Disabled, not hidden: a runner-scoped admin still lists and
               revokes on this page, so a vanished New key reads as a bug where
               a locked one reads as a rule. The tooltip carries the reason. --%>
          <.tooltip id="new-key-lock" text={issue_key_lock_text()}>
            <.button size={:md} icon="state.locked" disabled={true}>New key</.button>
          </.tooltip>
        <% end %>
      </:actions>

      <.page_intro :if={@live_action == :index}>
        Enrollment keys register new runners with emisar. Create keys for individual hosts
        or automated fleet setup.
        <.doc_link href={~p"/docs/runner-fleet#enrollment-keys"}>Enrollment docs</.doc_link>
      </.page_intro>

      <.page_intro :if={@live_action == :new}>
        Create a key to register new runners from an install command or your provisioning tools.
        <.doc_link href={~p"/docs/runner-fleet#enrollment-keys"}>Enrollment docs</.doc_link>
      </.page_intro>

      <%!-- ===== Create an enrollment key — its own focused page (:new) =====
           CONTENT ON CANVAS, task + rail (the install-wizard grammar) at the
           same 7xl column as the list it's reached from, so the header never
           jumps: the form (or its success reveal) is the task on the left; the
           key-choice and lifecycle help fills the rail on the right. --%>
      <%!-- Task column is sized to a readable FORM width (36rem), not 1fr —
           a 3-field form shouldn't stretch to fill the 7xl column; at xl the
           rail sits right beside it without becoming wider than the task. --%>
      <div
        :if={@live_action == :new}
        class="xl:grid xl:grid-cols-[minmax(0,36rem)_22rem] xl:gap-x-16"
      >
        <div class="space-y-8">
          <.runner_cap_callout billing={@billing} current_account={@current_account} />

          <%!-- Created: the secret is shown once. The alert spine owns its
               explanation, both copy artifacts, and the next actions. --%>
          <div :if={@new_secret}>
            <.event_block
              icon="identity.credential"
              tone={:amber}
              title="Enrollment key created"
            >
              <:body>
                Copy the key now — it won't be shown again. Keep it private;
                anyone with it can register runners.
              </:body>

              <.code_panel
                id="new-enrollment-key"
                label="Enrollment key"
                copy
                copy_label="Copy key"
                code={@new_secret}
                class="mt-6"
              />

              <.code_panel
                :if={is_binary(@install_command)}
                id="install-command"
                label="Install a runner"
                annotation="contains your enrollment key"
                prompt
                copy
                code={@install_command}
                class="mt-6"
              />

              <p :if={is_binary(@install_command)} class="mt-2 text-xs leading-relaxed text-zinc-400">
                Run this command on the host where you want to install the runner.
              </p>

              <.status_note
                :if={@install_command == :insecure_transport}
                icon="security.posture_warning"
                tone={:rose}
                title="Open emisar over HTTPS"
                class="mt-6"
              >
                The key above is still valid. Copy it now, then use the <.link
                  href={~p"/docs/host-install"}
                  class="font-medium text-brand-400 hover:text-brand-300"
                >manual runner install instructions</.link>.
                Open the portal over HTTPS before generating another install command.
              </.status_note>

              <.install_command_unavailable
                :if={@install_command == :unavailable}
                variant={:note}
                class="mt-6"
              />

              <div class="mt-6 flex flex-wrap items-center gap-3">
                <.button phx-click="dismiss_secret" icon="action.add">Create another</.button>
                <.button navigate={~p"/app/#{@current_account}/runners/keys"} variant={:secondary}>
                  Back to enrollment keys
                </.button>
              </div>
            </.event_block>
          </div>

          <.simple_form
            :if={is_nil(@new_secret)}
            for={@form}
            id="enrollment_key_form"
            phx-change="validate"
            phx-submit="create"
          >
            <.input
              field={@form[:description]}
              type="text"
              label="Description (optional)"
              placeholder="Production web servers"
            />
            <div class="space-y-1.5">
              <.input
                field={@form[:expires_at]}
                type="datetime-local"
                label="Expiration date (UTC, optional)"
              />
              <p class="text-xs leading-relaxed text-zinc-400">
                Leave blank for no expiration date.
              </p>
            </div>
            <div class="space-y-1.5">
              <.input
                field={@form[:reusable]}
                type="checkbox"
                label="Reusable key"
              />
              <p class="text-xs leading-relaxed text-zinc-400">
                Allow multiple runners to register with this key. Otherwise, it can be used once.
              </p>
            </div>
            <%!-- Max-uses only applies when Reusable is checked — single-use
                 keys self-cap at 1. Hiding it (vs disabling with a disclaimer)
                 is the same progressive-disclosure rule the agents wizard uses:
                 don't ask irrelevant questions. It reappears with its inline
                 hint the moment the reusable checkbox flips on. --%>
            <div :if={truthy?(@form[:reusable].value)} class="space-y-1.5">
              <.input
                field={@form[:max_uses]}
                type="number"
                min="1"
                label="Use limit (optional)"
                placeholder="Unlimited"
              />
              <p class="text-xs leading-relaxed text-zinc-400">
                Each runner registration counts as one use. Leave blank for unlimited uses.
              </p>
            </div>
            <:actions>
              <.button phx-disable-with="Creating…">Create key</.button>
              <.button navigate={~p"/app/#{@current_account}/runners/keys"} variant={:ghost}>
                Cancel
              </.button>
            </:actions>
          </.simple_form>
        </div>

        <div class="mt-10 xl:mt-0">
          <.new_enrollment_key_help />
        </div>
      </div>

      <div
        :if={@live_action == :index}
        id="enrollment-key-filters"
        phx-hook="EnrollmentKeyFilters"
        data-preference-key={"enrollment-key-source:#{@current_user.id}:#{@current_account.id}"}
        data-source={@filter_params["source"] || ""}
        data-source-explicit={to_string(Map.has_key?(@filter_params, "source"))}
        class="grid grid-cols-1 gap-x-10 gap-y-8 xl:grid-cols-[minmax(0,1fr)_22rem] xl:items-start"
      >
        <div class="space-y-6">
          <%!-- The same cap warning as the issue page — standing context while
               managing keys, so "you're at cap" isn't a surprise at New key. --%>
          <.runner_cap_callout billing={@billing} current_account={@current_account} />

          <%!-- Key list — the LiveTable :cards shell renders the filter row, the
               bordered card list, and the count in its paginator footer, so this
               page matches audit / runs. The page heading is the console_shell
               <:title> above — no extra section card around it. --%>
          <LiveTable.live_table
            layout={:cards}
            id="enrollment-keys"
            path={~p"/app/#{@current_account}/runners/keys"}
            rows={@enrollment_keys}
            metadata={@metadata}
            filters={@filters}
            filter_params={@filter_params}
            wrapper_class="divide-y divide-zinc-800/70"
          >
            <%!-- Canvas rows; the per-row icon disc died with the island. --%>
            <:item :let={key}>
              <.list_row padding="py-4">
                <:title>
                  <span class="truncate font-medium text-zinc-100">
                    {key.description || "(no description)"}
                  </span>
                </:title>
                <:chips>
                  <.chip :if={key.reusable} tone={:amber}>Reusable</.chip>
                  <%!-- A reusable key with no expiry is a standing fleet-enrollment secret —
                       flag it amber so a long-lived multi-host credential isn't read as routine. --%>
                  <.chip
                    :if={key.reusable and is_nil(key.expires_at) and is_nil(key.revoked_at)}
                    tone={:amber}
                  >
                    No expiration date
                  </.chip>
                  <%= case Runners.enrollment_key_status(key) do %>
                    <% :revoked -> %>
                      <.chip tone={:rose}>Revoked</.chip>
                    <% :expired -> %>
                      <.chip>Expired</.chip>
                    <% :spent -> %>
                      <.chip>Used up</.chip>
                    <% :active -> %>
                  <% end %>
                </:chips>
                <:meta>
                  <.meta_line class="text-[11px]">
                    <:seg mono>{key.key_prefix}…</:seg>
                    <:seg><span class="tabular-nums">{key_usage(key)}</span></:seg>
                    <:seg>
                      last used{" "}<.local_time
                        id={"enrollment-key-used-#{key.id}"}
                        value={key.last_used_at}
                        mode={:relative}
                        placeholder="never"
                      />
                    </:seg>
                    <:seg :if={key.created_by}>by {key.created_by.email}</:seg>
                    <:seg :if={key.expires_at}>
                      {if DateTime.compare(key.expires_at, DateTime.utc_now()) == :gt,
                        do: "expires",
                        else: "expired"}{" "}<.local_time
                        id={"enrollment-key-expiry-#{key.id}"}
                        value={key.expires_at}
                        mode={:relative}
                      />
                    </:seg>
                  </.meta_line>
                </:meta>
                <:actions>
                  <%!-- Navigation, but this row's action group also carries a bordered
                       Revoke, and a row wears ONE button grammar (§7.47). The face is
                       the ROW's, not the per-row permission state's — restyling it when
                       Revoke is absent would move the layout between states (§7.55). --%>
                  <.button
                    navigate={
                      ~p"/app/#{@current_account}/audit?#{[target_kind: "enrollment_key", target_id: key.id]}"
                    }
                    variant={:secondary}
                    size={:sm}
                  >
                    View activity
                  </.button>
                  <%!-- Plain confirm — revoking doesn't disconnect anyone (existing
                       runners keep their tokens) and is undone by issuing a fresh
                       key, so it doesn't earn a type-to-confirm. The button only
                       OPENS the dialog; `revoke` still fires from Confirm and stays
                       server-authz-gated (subject_can_revoke_enrollment_keys?). --%>
                  <.button
                    :if={
                      is_nil(key.revoked_at) and
                        @can_revoke_keys?
                    }
                    variant={:secondary}
                    tone={:rose}
                    size={:sm}
                    type="button"
                    phx-click={open_confirm("revoke-key-#{key.id}")}
                  >
                    Revoke
                  </.button>
                  <.confirm_dialog
                    :if={
                      is_nil(key.revoked_at) and
                        @can_revoke_keys?
                    }
                    id={"revoke-key-#{key.id}"}
                    title="Revoke this enrollment key?"
                    confirm_label="Revoke key"
                    on_confirm={
                      JS.push("revoke", value: %{id: key.id})
                      |> close_confirm("revoke-key-#{key.id}")
                    }
                  >
                    <:body>
                      Revoking
                      <span class="font-mono font-medium text-zinc-200">{key.key_prefix}…</span>
                      blocks new registrations. Registered runners stay connected. This can't be undone.
                    </:body>
                  </.confirm_dialog>
                </:actions>
              </.list_row>
            </:item>
            <:empty>
              <%!-- Dead/pre-connect render: the list hasn't been read yet, so don't
                   claim the account has no keys. --%>
              <.loading_state :if={not connected?(@socket)} />
              <.empty_state
                :if={connected?(@socket) and @load_error?}
                icon="state.warning"
                title="Could not load enrollment keys"
              >
                Refresh the page to try again.
              </.empty_state>
              <.empty_state
                :if={
                  connected?(@socket) and not @load_error? and
                    LiveTable.has_active_filters?(@filter_params, @filters)
                }
                icon="action.filter"
                title="No matching enrollment keys"
              >
                Clear the filters to see other keys.
              </.empty_state>
              <.empty_state
                :if={
                  connected?(@socket) and not @load_error? and
                    not LiveTable.has_active_filters?(@filter_params, @filters)
                }
                icon="identity.credential"
                title="No active enrollment keys"
              >
                <p :if={@can_create_keys?}>
                  Create a key to register runners. Keys generated during runner setup also appear here.
                </p>
                <p :if={not @can_create_keys?}>
                  Ask an owner or admin to create a key when you need one.
                </p>
                <.button
                  :if={@can_create_keys?}
                  navigate={~p"/app/#{@current_account}/runners/keys/new"}
                  variant={:secondary}
                  size={:sm}
                  icon="action.add"
                  class="mt-4"
                >
                  New enrollment key
                </.button>
                <p
                  :if={not @can_create_keys?}
                  class="mt-4 text-xs text-zinc-400"
                >
                  {issue_key_lock_text()}
                </p>
              </.empty_state>
            </:empty>
          </LiveTable.live_table>
        </div>

        <.enrollment_key_help />
      </div>
    </.console_shell>
    """
  end

  defp new_enrollment_key_help(assigns) do
    ~H"""
    <.docs_rail title="Using your key">
      <p>
        For automated provisioning, keep reusable keys in your secret manager and pass them
        to hosts during setup.
        <.doc_link href={~p"/docs/host-install#config"}>Runner configuration</.doc_link>
      </p>
      <p>
        During registration, each runner exchanges the enrollment key for its own connection
        key. If the enrollment key expires or is revoked, registered runners stay connected.
        <.doc_link href={~p"/docs/runner-credentials#enrollment-keys"}>How runner keys work</.doc_link>
      </p>
    </.docs_rail>
    """
  end

  defp enrollment_key_help(assigns) do
    ~H"""
    <.docs_rail title="Choosing and revoking keys">
      <p>
        Use a single-use key for one host. Reusable keys can register multiple hosts until
        they expire, reach a use limit, or are revoked.
      </p>
      <p>
        After enrollment, each runner connects with its own key. Revoking an enrollment key
        blocks new registrations without disconnecting existing runners.
        <.doc_link href={~p"/docs/runner-credentials"}>How runner keys work</.doc_link>
      </p>
    </.docs_rail>
    """
  end

  # Runner-cap warning: a key minted here is useless if the runner that tries
  # to use it bounces off a 402. Shown on the issue page (the decision point)
  # and the list (standing awareness) — renders nothing below the warning band.
  attr :billing, :any, required: true
  attr :current_account, :map, required: true

  defp runner_cap_callout(assigns) do
    ~H"""
    <.callout
      :if={@billing && Emisar.Billing.headroom(@billing, :runners) in [:warning, :at_limit]}
      tone={runner_cap_tone(@billing)}
      icon="state.warning"
      title={runner_cap_title(@billing)}
    >
      {@billing.runner_count} of {@billing.runner_limit} runners in use.
      Creating a key doesn't reserve a slot — the runner only counts after it registers.
      <.doc_link href={~p"/docs/limits"}>Plan limits docs</.doc_link>
      <:action>
        <.button
          variant={:secondary}
          size={:md}
          class="group"
          navigate={~p"/app/#{@current_account}/settings/billing"}
        >
          See plans <.cta_arrow />
        </.button>
      </:action>
    </.callout>
    """
  end

  defp runner_cap_tone(billing) do
    if Emisar.Billing.headroom(billing, :runners) == :at_limit, do: :rose, else: :amber
  end

  defp runner_cap_title(billing) do
    if Emisar.Billing.headroom(billing, :runners) == :at_limit do
      "At runner limit — new installs will fail."
    else
      "One runner slot left on the #{String.capitalize(billing.plan)} plan."
    end
  end
end
