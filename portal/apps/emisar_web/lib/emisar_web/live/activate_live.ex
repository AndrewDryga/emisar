defmodule EmisarWeb.ActivateLive do
  @moduledoc """
  The device-grant approval page (`/app/:slug/activate`) — where the MCP
  installer's printed code turns into per-client API keys. Renders as the
  OAuth-consent card (centered, no dashboard chrome): the same surface an
  operator already trusts for Claude.ai/ChatGPT authorization, because it is
  the same decision. Shows the pending request's facts, makes the destination
  account an explicit part of the decision, and approves or denies it. The
  installer's poll picks the outcome up on its own; this page never shows a
  secret.
  """
  use EmisarWeb, :live_view
  alias Emisar.{Accounts, ApiKeys}
  alias EmisarWeb.Permissions

  def mount(_params, _session, socket) do
    # IL-18: the selector read runs on the connected mount only; a
    # single-account user (the common case) just never sees the selector
    # during the static flash.
    accounts =
      if connected?(socket),
        do: list_switchable_accounts(socket.assigns.current_subject),
        else: [socket.assigns.current_account]

    {:ok,
     socket
     |> assign(:page_title, "Approve an agent connection")
     |> assign(:accounts, accounts)
     |> assign(:grant, nil)
     |> assign(:decision, nil)
     |> assign(:lookup_error, nil)
     |> assign(:code, "")}
  end

  def handle_params(params, _uri, socket) do
    code = params["code"] || socket.assigns.code

    socket =
      socket
      |> assign(:code, code)
      |> assign(:code_form, to_form(%{"code" => code}, as: :lookup))

    # The static pass renders the form shell; the connected pass resolves a
    # URL-carried code straight into the approval card (IL-18).
    if connected?(socket) and code != "" and is_nil(socket.assigns.decision) do
      {:noreply, lookup(socket, code)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("lookup", %{"lookup" => %{"code" => code}}, socket) do
    code = String.trim(code)

    if code == "" do
      {:noreply, assign(socket, lookup_error: "Enter the code shown in your terminal.")}
    else
      {:noreply, socket |> assign(:code, code) |> lookup(code)}
    end
  end

  def handle_event("pick_account", %{"account" => slug}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/app/#{slug}/activate?code=#{socket.assigns.code}")}
  end

  def handle_event("approve", _params, socket) do
    subject = socket.assigns.current_subject

    Permissions.gated(socket, ApiKeys.subject_can_issue_quick_key?(subject), fn socket ->
      case ApiKeys.approve_device_grant(socket.assigns.code, subject) do
        {:ok, grant} ->
          {:noreply, socket |> assign(:grant, grant) |> assign(:decision, :approved)}

        {:error, :not_found} ->
          {:noreply, socket |> assign(:grant, nil) |> assign(:lookup_error, gone_message())}

        {:error, :unauthorized} ->
          {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}
      end
    end)
  end

  def handle_event("deny", _params, socket) do
    subject = socket.assigns.current_subject

    Permissions.gated(socket, ApiKeys.subject_can_issue_quick_key?(subject), fn socket ->
      case ApiKeys.deny_device_grant(socket.assigns.code, subject) do
        {:ok, grant} ->
          {:noreply, socket |> assign(:grant, grant) |> assign(:decision, :denied)}

        {:error, :not_found} ->
          {:noreply, socket |> assign(:grant, nil) |> assign(:lookup_error, gone_message())}

        {:error, :unauthorized} ->
          {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}
      end
    end)
  end

  defp lookup(socket, code) do
    case ApiKeys.fetch_pending_device_grant_by_user_code(code, socket.assigns.current_subject) do
      {:ok, grant} ->
        socket |> assign(:grant, grant) |> assign(:lookup_error, nil)

      {:error, :not_found} ->
        socket |> assign(:grant, nil) |> assign(:lookup_error, gone_message())

      {:error, :unauthorized} ->
        # The card already renders the honest role note; keep the form inert.
        socket
    end
  end

  defp gone_message do
    "No pending request matches this code — it may have expired (codes last " <>
      "15 minutes) or already been decided. Re-run the installer for a fresh one."
  end

  defp list_switchable_accounts(subject) do
    case Accounts.list_accounts_for_user(subject) do
      {:ok, accounts, _metadata} -> accounts
      {:error, _reason} -> []
    end
  end

  def render(assigns) do
    ~H"""
    <.auth_card>
      <%= cond do %>
        <% not ApiKeys.subject_can_issue_quick_key?(@current_subject) -> %>
          <div class="px-6 py-5">
            <h1 class="text-lg font-semibold text-zinc-50">Operator access needed</h1>
            <p class="mt-3 text-sm leading-relaxed text-zinc-400">
              Approving an agent connection needs an operator role or above. Ask an
              operator, admin, or owner to approve it — the code from the terminal is
              all they need.
            </p>
          </div>
        <% @decision == :approved -> %>
          <div class="px-6 py-5">
            <div class="flex items-center gap-2.5">
              <.icon name="hero-check-circle" class="h-6 w-6 flex-none text-brand-400" />
              <h1 class="text-lg font-semibold text-zinc-50">
                Approved — return to your terminal
              </h1>
            </div>
            <p class="mt-3 text-sm leading-relaxed text-zinc-400">
              The installer picks this up within seconds and writes each client's
              config itself. The new agents appear in Agents after their first call —
              revoke them there anytime.
            </p>
            <.link
              navigate={~p"/app/#{@current_account}/agents"}
              class="mt-5 block w-full rounded-lg border border-zinc-700 px-4 py-2.5 text-center text-sm font-medium text-zinc-300 transition hover:bg-zinc-800"
            >
              Go to Agents
            </.link>
          </div>
        <% @decision == :denied -> %>
          <div class="px-6 py-5">
            <div class="flex items-center gap-2.5">
              <.icon name="hero-hand-raised" class="h-6 w-6 flex-none text-zinc-400" />
              <h1 class="text-lg font-semibold text-zinc-50">
                Denied — the installer stops
              </h1>
            </div>
            <p class="mt-3 text-sm leading-relaxed text-zinc-400">
              The request is dead; its code can't be approved later. If this wasn't
              you, nothing was connected — and nothing can be until someone with
              access approves a fresh code.
            </p>
          </div>
        <% @grant -> %>
          <div class="border-b border-zinc-800 px-6 py-5">
            <h1 class="text-lg font-semibold text-zinc-50">
              Connect <span class="text-brand-400">{client_labels_phrase(@grant)}</span>
            </h1>
            <p class="mt-1 text-sm text-zinc-400">
              requested by the emisar installer from
              <span class="font-mono text-[0.92em] text-zinc-300">
                {@grant.requester_ip || "an unknown address"}
              </span>
            </p>
            <p class="mt-2 text-xs text-zinc-500">
              code
              <span class="font-mono text-[0.92em] text-zinc-400">
                {@code |> String.trim() |> String.upcase()}
              </span>
              · expires {expires_phrase(@grant)}
            </p>
          </div>

          <div class="px-6 py-5">
            <p class="text-xs font-medium uppercase tracking-wide text-zinc-500">
              Approving this will
            </p>
            <ul class="mt-3 space-y-3">
              <li class="flex items-start gap-3">
                <.icon
                  name="hero-check-circle"
                  class="mt-0.5 h-5 w-5 flex-none text-brand-400"
                />
                <span class="text-sm leading-snug text-zinc-300">
                  Create {key_count_phrase(@grant)} in
                  <strong class="text-zinc-100">{@current_account.name}</strong>
                </span>
              </li>
              <li class="flex items-start gap-3">
                <.icon
                  name="hero-check-circle"
                  class="mt-0.5 h-5 w-5 flex-none text-brand-400"
                />
                <span class="text-sm leading-snug text-zinc-300">
                  {delivery_phrase(@grant)}
                </span>
              </li>
            </ul>

            <.consent_note class="mt-5">
              <strong class="text-zinc-300">Only approve a request you just started
              yourself.</strong>
              The keys can only run what your policy already permits — risky actions
              still pause for human approval, and every call is audited.
            </.consent_note>

            <%!-- Which account the keys land in. A member of several accounts picks
                     at the point of decision (preselected to the current one — picking
                     re-enters this page under that account's slug, so the subject is
                     rebuilt by the auth boundary and per-account permissions apply);
                     a single-account member sees the destination named in the
                     consequence line above. --%>
            <form
              :if={length(@accounts) > 1}
              id="activate-account-form"
              phx-change="pick_account"
              class="mt-5"
            >
              <.input
                type="select"
                id="activate-account"
                name="account"
                label="Approve into"
                label_variant={:eyebrow}
                value={@current_account.slug}
                options={Enum.map(@accounts, &{&1.name, &1.slug})}
              />
            </form>

            <div class="mt-6 flex flex-col gap-3">
              <button
                phx-click="approve"
                class="w-full rounded-lg bg-brand-500 px-4 py-2.5 text-sm font-semibold text-white transition hover:bg-brand-400 focus:outline-none focus:ring-2 focus:ring-brand-400 focus:ring-offset-2 focus:ring-offset-zinc-900"
              >
                Approve connection
              </button>
              <button
                phx-click="deny"
                class="w-full rounded-lg border border-zinc-700 px-4 py-2.5 text-sm font-medium text-zinc-300 transition hover:bg-zinc-800"
              >
                Deny
              </button>
            </div>
          </div>
        <% true -> %>
          <div class="border-b border-zinc-800 px-6 py-5">
            <h1 class="text-lg font-semibold text-zinc-50">Approve an agent connection</h1>
            <p class="mt-1 text-sm text-zinc-400">
              Enter the approval code shown by the installer in your terminal.
            </p>
          </div>
          <div class="px-6 py-5">
            <.form for={@code_form} phx-submit="lookup">
              <.input
                field={@code_form[:code]}
                type="text"
                label="Approval code"
                label_variant={:eyebrow}
                placeholder="FKZQ-2418"
                autocomplete="off"
              />
              <p :if={@lookup_error} class="mt-2 text-sm leading-relaxed text-rose-400">
                {@lookup_error}
              </p>
              <button
                type="submit"
                class="mt-5 w-full rounded-lg bg-brand-500 px-4 py-2.5 text-sm font-semibold text-white transition hover:bg-brand-400 focus:outline-none focus:ring-2 focus:ring-brand-400 focus:ring-offset-2 focus:ring-offset-zinc-900"
              >
                Find request
              </button>
            </.form>
          </div>
      <% end %>

      <:footer>
        Signed in as <span class="text-zinc-400">{@current_user.email}</span>
      </:footer>
    </.auth_card>
    """
  end

  # "Claude Code" / "Claude Code & Cursor" / "Claude Code, Cursor & Codex CLI"
  defp client_labels_phrase(grant) do
    case Enum.map(grant.requested_clients, &ApiKeys.DeviceGrant.client_label/1) do
      [one] -> one
      [a, b] -> "#{a} & #{b}"
      many -> Enum.join(Enum.drop(many, -1), ", ") <> " & " <> List.last(many)
    end
  end

  defp expires_phrase(grant) do
    minutes = grant.expires_at |> DateTime.diff(DateTime.utc_now(), :minute) |> max(0)

    case minutes do
      0 -> "under a minute from now"
      1 -> "in about a minute"
      n -> "in about #{n} minutes"
    end
  end

  defp delivery_phrase(grant) do
    case length(grant.requested_clients) do
      1 -> "Deliver it to that machine once and write the client's config"
      _many -> "Deliver them to that machine once and write each client's config"
    end
  end

  defp key_count_phrase(grant) do
    case length(grant.requested_clients) do
      1 -> "1 API key"
      n -> "#{n} API keys (one per client)"
    end
  end
end
