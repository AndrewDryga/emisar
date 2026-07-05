defmodule EmisarWeb.EnrollmentKeysLive do
  use EmisarWeb, :live_view
  alias Emisar.Runners
  alias EmisarWeb.{ConfirmDialog, LiveTable, Permissions, UrlHelpers}
  alias Phoenix.LiveView.JS

  def mount(_params, _session, socket) do
    # Manage-only page (auth keys have no view-only permission): anyone
    # without manage lands on not-found at LOAD time, not on first submit.
    if Runners.subject_can_manage_enrollment_keys?(socket.assigns.current_subject) do
      # Subscribe to the per-account auth-keys topic so another operator's
      # create / revoke (or an auto-bind from a runner registration) reflows
      # this list without the viewer having to refresh.
      if connected?(socket),
        do: Runners.subscribe_account_enrollment_keys(socket.assigns.current_account.id)

      {:ok,
       socket
       |> assign(:page_title, "Enrollment keys")
       |> assign(:new_secret, nil)
       |> assign(:new_key, nil)
       |> assign(:base_url, UrlHelpers.derive_base_url(socket))
       # IL-18: only hit the billing read on the connected mount; the
       # cap-warning banner just stays hidden until it loads.
       |> assign(:billing, connected?(socket) && fetch_billing(socket))
       |> ConfirmDialog.init()
       |> assign_form(Runners.change_enrollment_key())}
    else
      {:ok,
       socket
       |> put_flash(:info, "Enrollment keys need an owner or admin role.")
       |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/runners")}
    end
  end

  def handle_params(params, _uri, socket) do
    page_title =
      if socket.assigns.live_action == :new,
        do: "Issue an enrollment key",
        else: "Enrollment keys"

    {:noreply, socket |> assign(:page_title, page_title) |> load(params)}
  end

  def handle_info({:list_changed, :enrollment_key, _event_type, _id}, socket),
    do: {:noreply, load(socket, socket.assigns[:filter_params] || %{})}

  def handle_info(_, socket), do: {:noreply, socket}

  defp fetch_billing(socket) do
    case Emisar.Billing.billing_summary(
           socket.assigns.current_account,
           socket.assigns.current_subject
         ) do
      {:ok, summary} -> summary
      {:error, _} -> nil
    end
  end

  def handle_event("validate", %{"enrollment_key" => params}, socket) do
    changeset = Runners.change_enrollment_key(params) |> Map.put(:action, :validate)
    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("create", %{"enrollment_key" => params}, socket) do
    Permissions.gated(
      socket,
      Runners.subject_can_manage_enrollment_keys?(socket.assigns.current_subject),
      &do_create(&1, params)
    )
  end

  def handle_event("dismiss_secret", _params, socket) do
    {:noreply,
     socket
     |> assign(:new_secret, nil)
     |> assign(:new_key, nil)}
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    Permissions.gated(
      socket,
      Runners.subject_can_manage_enrollment_keys?(socket.assigns.current_subject),
      &do_revoke(&1, id)
    )
  end

  # Typed-confirm state for the "Revoke auth key" dialog (UX friction only —
  # `revoke` above stays the server gate).
  def handle_event("confirm_typed", params, socket),
    do: {:noreply, ConfirmDialog.put_typed(socket, params)}

  def handle_event("confirm_reset", _params, socket),
    do: {:noreply, ConfirmDialog.reset(socket)}

  def handle_event("filter", params, socket) do
    {:noreply,
     LiveTable.apply_filter(
       socket,
       ~p"/app/#{socket.assigns.current_account}/runners/keys",
       params,
       Runners.EnrollmentKey.Query.filters()
     )}
  end

  defp do_create(socket, params) do
    changeset = Runners.change_enrollment_key(params)

    if changeset.valid? do
      attrs =
        %{}
        |> put_if_present(:description, params["description"])
        |> Map.put(:reusable, truthy?(params["reusable"]))
        |> put_expires(params["expires_at"])
        |> put_max_uses(params["max_uses"])

      case Runners.create_enrollment_key(attrs, socket.assigns.current_subject) do
        {:ok, raw, key} ->
          # The reveal IS the success step on the /new page — no flash, and no
          # list reload (the list isn't shown here; :index remounts fresh).
          {:noreply,
           socket
           |> assign(:new_secret, raw)
           |> assign(:new_key, key)
           |> assign_form(Runners.change_enrollment_key())}

        # Field errors (e.g. a DB constraint) render inline on the form.
        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign_form(socket, changeset)}
      end
    else
      {:noreply, assign_form(socket, Map.put(changeset, :action, :insert))}
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

  defp load(socket, params) do
    # Revoked keys hide by default via the status filter's `%Filter{default:}` —
    # LiveTable resolves absent → "active" and keeps an explicit "All" in the
    # URL (apply_filter gets the filters below), so no param injection here.
    filters = Runners.EnrollmentKey.Query.filters()
    opts = LiveTable.params_to_opts(params, filters)

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

      # A clean reload can fail too (e.g. the subject can't list keys) —
      # degrade to an empty list rather than recursing forever.
      {:error, _} when map_size(params) == 0 ->
        socket
        |> assign(:enrollment_keys, [])
        |> assign(:metadata, %Emisar.Repo.Paginator.Metadata{count: 0, limit: 0})
        |> assign(:filter_params, params)
        |> assign(:filters, filters)

      # Bad filter/page params from a hand-edited URL — retry once, clean.
      {:error, _} ->
        load(socket, %{})
    end
  end

  # Only set max_uses when reusable AND a positive integer was typed —
  # single-use keys ignore it (they self-cap at 1 via the schema), and
  # an empty string means "unlimited within the reusable window".
  defp put_max_uses(map, value) when value in [nil, ""], do: map

  defp put_max_uses(map, value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> Map.put(map, :max_uses, n)
      _ -> map
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset, as: "enrollment_key"))
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp put_expires(map, value) when value in [nil, ""], do: map

  defp put_expires(map, value) when is_binary(value) do
    case DateTime.from_iso8601(value <> ":00Z") do
      {:ok, datetime, _} -> Map.put(map, :expires_at, datetime)
      _ -> map
    end
  end

  defp truthy?("true"), do: true
  defp truthy?(true), do: true
  defp truthy?("on"), do: true
  defp truthy?(_), do: false

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
      width={:table}
    >
      <:title>
        <%= if @live_action == :new do %>
          <.back_link navigate={~p"/app/#{@current_account}/runners"}>Runners</.back_link>
          <.back_link navigate={~p"/app/#{@current_account}/runners/keys"}>
            Enrollment keys
          </.back_link>
          Issue an enrollment key
        <% else %>
          <.back_link navigate={~p"/app/#{@current_account}/runners"}>Runners</.back_link>
          Enrollment keys
        <% end %>
      </:title>
      <:actions :if={
        @live_action == :index and Runners.subject_can_manage_enrollment_keys?(@current_subject)
      }>
        <.button navigate={~p"/app/#{@current_account}/runners/keys/new"} size={:md} icon="hero-plus">
          New key
        </.button>
      </:actions>

      <%!-- ===== Issue an enrollment key — its own focused page (:new) =====
           CONTENT ON CANVAS, task + rail (the install-wizard grammar) at the
           same 7xl column as the list it's reached from, so the header never
           jumps: the form (or its success reveal) is the task on the left; the
           "what is this" explainer fills the rail on the right. --%>
      <%!-- Task column is sized to a readable FORM width (36rem), not 1fr —
           a 3-field form shouldn't stretch to fill the 7xl column; the rail
           sits right beside it. --%>
      <div
        :if={@live_action == :new}
        class="lg:grid lg:grid-cols-[minmax(0,36rem)_22rem] lg:gap-x-16"
      >
        <div class="space-y-8">
          <.runner_cap_callout billing={@billing} current_account={@current_account} />

          <%!-- Created: the secret is shown ONCE — the reveal IS the success
               step, in the naked credential grammar the agents page uses
               (status_note + code_panel artifacts on canvas), NOT a boxed
               banner. The secret + install command are the earned code
               artifacts; the note is the posture line above them. --%>
          <div :if={@new_secret} class="space-y-6">
            <.status_note
              icon="hero-key"
              tone={:amber}
              title="Copy this enrollment key now — it won't be shown again."
              primary
            >
              Treat it like a password. Anyone with this key can register a runner under <span class="font-medium text-zinc-200">{@current_account.name}</span>.
            </.status_note>

            <.code_panel
              id="new-enrollment-key"
              label="Enrollment key"
              copy
              copy_label="Copy key"
              code={@new_secret}
            />

            <.code_panel
              id="install-command"
              label="Install on a host"
              annotation="contains your enrollment key"
              prompt
              copy
              copy_label="Copy command"
              code={"curl -sSL #{@base_url}/install.sh | sudo EMISAR_AUTH_KEY=#{@new_secret} EMISAR_URL=#{@base_url} bash"}
            />

            <div class="flex flex-wrap items-center gap-3">
              <.button phx-click="dismiss_secret" icon="hero-plus">Issue another</.button>
              <.button navigate={~p"/app/#{@current_account}/runners/keys"} variant={:secondary}>
                Back to enrollment keys
              </.button>
            </div>
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
              label="Description"
              placeholder="prod web tier"
            />
            <.input
              field={@form[:expires_at]}
              type="datetime-local"
              label="Expires at (UTC, optional)"
            />
            <.input
              field={@form[:reusable]}
              type="checkbox"
              label="Reusable (many runners can register with this key)"
            />
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
                label="Max uses"
                placeholder="unlimited"
              />
              <p class="text-xs leading-relaxed text-zinc-500">
                Caps how many runners can register before the key auto-revokes.
                Leave blank for unlimited.
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

        <%!-- The reading rail — what an enrollment key IS and how its lifecycle
             works, so an operator issuing one understands the exchange and
             the revoke semantics before they mint a root-capable secret. --%>
        <aside class="mt-10 lg:mt-0">
          <.section_header title="What an enrollment key is" />
          <div class="space-y-4 text-sm leading-relaxed text-zinc-400">
            <p>
              A bearer secret a fresh host presents to
              <span class="font-medium text-zinc-300">enroll</span>
              as a runner. The host runs the install command with it, registers, and trades it for
              its own long-lived token — the key isn't used again for that host.
            </p>
            <p>
              A <span class="font-medium text-zinc-300">single-use</span>
              key is spent on the first registration — right for an autoscaler baking one host at a
              time. A <span class="font-medium text-zinc-300">reusable</span>
              key keeps enrolling hosts until it expires or hits its max-uses cap — right for a
              stable fleet or an image bake.
            </p>
            <p>
              <span class="font-medium text-zinc-300">Revoking is safe.</span>
              It blocks new registrations with this key — a host presenting a revoked key gets a 401.
              Runners already enrolled keep running under their own tokens; revoke never disconnects
              or deletes them.
            </p>
            <p class="pt-1">
              <.doc_link href="/docs/runners">Runner setup docs</.doc_link>
            </p>
          </div>
        </aside>
      </div>

      <.page_intro :if={@live_action == :index}>
        Enrollment keys register new hosts as runners — a single-use key is spent on first
        registration; a reusable key keeps enrolling hosts until it expires or hits its max-uses cap.
        <.doc_link href="/docs/runners">Runner setup docs</.doc_link>
      </.page_intro>

      <div :if={@live_action == :index} class="space-y-6">
        <%!-- The same cap warning as the issue page — standing context while
             managing keys, so "you're at cap" isn't a surprise at New key. --%>
        <.runner_cap_callout billing={@billing} current_account={@current_account} />

        <%!-- Key list — the LiveTable :cards shell renders the filter row, the
             bordered card list, and the count in its paginator footer, so this
             page matches audit / runs. The page heading is the dashboard_shell
             <:title> above — no extra section card around it. --%>
        <LiveTable.live_table
          layout={:cards}
          id="auth-keys"
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
                <.chip :if={key.reusable}>reusable</.chip>
                <%!-- A reusable key with no expiry is a standing fleet-enrollment secret —
                     flag it amber so a long-lived multi-host credential isn't read as routine. --%>
                <.chip
                  :if={key.reusable and is_nil(key.expires_at) and is_nil(key.revoked_at)}
                  tone={:amber}
                >
                  no expiry
                </.chip>
                <.chip :if={not key.reusable}>single-use</.chip>
                <.chip :if={key.revoked_at} tone={:rose}>revoked</.chip>
              </:chips>
              <:meta>
                <.meta_line class="text-[11px]">
                  <:seg mono>{key.key_prefix}…</:seg>
                  <:seg>{key.uses_count} {if key.uses_count == 1, do: "use", else: "uses"}</:seg>
                  <:seg>
                    last used{" "}<.local_time
                      value={key.last_used_at}
                      mode={:relative}
                      placeholder="never"
                    />
                  </:seg>
                  <:seg :if={key.created_by}>by {key.created_by.email}</:seg>
                </.meta_line>
              </:meta>
              <:actions>
                <%!-- Plain confirm — revoking doesn't disconnect anyone (existing
                     runners keep their tokens) and is undone by issuing a fresh
                     key, so it doesn't earn a type-to-confirm. The button only
                     OPENS the dialog; `revoke` still fires from Confirm and stays
                     server-authz-gated (subject_can_manage_enrollment_keys?). --%>
                <.button
                  :if={
                    is_nil(key.revoked_at) and
                      Runners.subject_can_manage_enrollment_keys?(@current_subject)
                  }
                  variant={:secondary}
                  tone={:rose}
                  size={:sm}
                  type="button"
                  phx-click={show_confirm_dialog("revoke-key-#{key.id}")}
                >
                  Revoke
                </.button>
                <.confirm_dialog
                  :if={is_nil(key.revoked_at)}
                  id={"revoke-key-#{key.id}"}
                  title="Revoke enrollment key"
                  confirm_label="Revoke key"
                  on_confirm={
                    JS.push("revoke", value: %{id: key.id})
                    |> hide_confirm_dialog("revoke-key-#{key.id}")
                  }
                >
                  <:body>
                    Permanently revokes <span class="font-mono font-medium text-zinc-200">{key.key_prefix}…</span>.
                    Existing runners aren't affected, but new registrations with this key will
                    fail. This can't be undone — issue a fresh key instead.
                  </:body>
                </.confirm_dialog>
              </:actions>
            </.list_row>
          </:item>
          <:empty>
            <.empty_state variant={:bare} icon="hero-key" title="No enrollment keys yet.">
              An enrollment key is the bearer secret a fresh host enrolls with — mint a
              reusable one for image bakes and cloud-init fleets. The install
              wizard's one-time keys appear here too, revocable until used.
              <.button
                :if={Runners.subject_can_manage_enrollment_keys?(@current_subject)}
                navigate={~p"/app/#{@current_account}/runners/keys/new"}
                variant={:secondary}
                size={:sm}
                icon="hero-plus"
                class="mt-4"
              >
                New enrollment key
              </.button>
            </.empty_state>
          </:empty>
        </LiveTable.live_table>

        <p
          :if={not Runners.subject_can_manage_enrollment_keys?(@current_subject)}
          class="text-xs text-zinc-500"
        >
          Only owners and admins can issue or revoke enrollment keys.
        </p>
      </div>
    </.dashboard_shell>
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
      icon="hero-exclamation-triangle"
      title={runner_cap_title(@billing)}
    >
      {@billing.runner_count} of {@billing.runner_limit} runners in use.
      Issuing a key doesn't reserve a slot — the runner only counts after it registers.
      <:action>
        <.button
          variant={:secondary}
          size={:md}
          navigate={~p"/app/#{@current_account}/settings/billing"}
        >
          See plans →
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
