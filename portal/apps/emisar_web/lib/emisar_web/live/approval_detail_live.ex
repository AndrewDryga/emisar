defmodule EmisarWeb.ApprovalDetailLive do
  use EmisarWeb, :live_view

  alias Emisar.{Accounts, Approvals, PubSub, Runners, Runs}
  alias EmisarWeb.Permissions

  def mount(%{"id" => id}, _session, socket) do
    account_id = socket.assigns.current_account.id
    subject = socket.assigns.current_subject

    case Approvals.fetch_approval_request_by_id(id, subject) do
      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Approval not found.")
         |> push_navigate(to: ~p"/app/approvals")}

      {:ok, req} ->
        if connected?(socket) do
          PubSub.subscribe_account_approvals(account_id)
          Runners.subscribe_connections(account_id)
        end

        run =
          case Runs.fetch_run_by_id(req.run_id, socket.assigns.current_subject) do
            {:ok, r} -> r
            {:error, _} -> nil
          end

        title = "Approval · " <> ((run && run.action_id) || String.slice(req.id, 0, 8))

        {:ok,
         socket
         |> assign(:page_title, title)
         |> assign(:request, req)
         |> assign(:run, run)
         |> assign(:runner_connection, runner_connection(run))
         |> assign(:requested_by, lookup_user(req.requested_by_id))
         |> assign(:decided_by, lookup_user(req.decided_by_id))
         |> assign(:decision_reason, "")
         # Tracks the duration the operator picked in the grant-reuse
         # disclosure. "once" (the default) means "no grant" — in that
         # mode the Match / Limit-to fields are irrelevant and hidden.
         |> assign(:grant_duration, "once")}
    end
  end

  # Resolves a user_id → email for the request/decision labels. Tolerates
  # missing rows (a since-removed user) by returning `nil` so the
  # template can fall back to a placeholder.
  defp lookup_user(nil), do: nil

  defp lookup_user(id) when is_binary(id) do
    case Accounts.fetch_user_by_id(id) do
      {:ok, user} -> user
      _ -> nil
    end
  end

  def handle_info({:approval_updated, %{id: id} = updated}, socket)
      when id == socket.assigns.request.id do
    {:noreply,
     socket
     |> assign(:request, updated)
     |> assign(:decided_by, lookup_user(updated.decided_by_id))}
  end

  # A runner connected/disconnected in the account — refresh the target
  # runner's online dot so the operator knows whether approving executes
  # now or queues.
  def handle_info(%{event: "presence_diff"}, socket) do
    {:noreply, assign(socket, :runner_connection, runner_connection(socket.assigns.run))}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  def handle_event("grant_form_changed", params, socket) do
    {:noreply, assign(socket, :grant_duration, params["duration"] || "once")}
  end

  def handle_event("approve", params, socket) do
    Permissions.gated(socket, :decide_approval, fn s ->
      opts = [
        duration: parse_duration(params["duration"]),
        scope: parse_scope(params["scope"]),
        max_uses: parse_max_uses(params["max_uses"])
      ]

      reason = blank_or(params["reason"])

      case Approvals.approve_request(s.assigns.request, s.assigns.current_subject, reason, opts) do
        {:ok, {req, _run}} ->
          msg = approval_flash(opts)
          {:noreply, s |> assign(:request, req) |> put_flash(:info, msg)}

        _ ->
          {:noreply, put_flash(s, :error, "Could not approve.")}
      end
    end)
  end

  def handle_event("deny", params, socket) do
    Permissions.gated(socket, :decide_approval, fn s ->
      case Approvals.deny_request(
             s.assigns.request,
             s.assigns.current_subject,
             blank_or(params["reason"])
           ) do
        {:ok, {req, _run}} ->
          {:noreply, s |> assign(:request, req) |> put_flash(:info, "Denied.")}

        _ ->
          {:noreply, put_flash(s, :error, "Could not deny.")}
      end
    end)
  end

  defp parse_max_uses(v) when is_binary(v) do
    case Integer.parse(String.trim(v)) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_max_uses(_), do: nil

  defp parse_duration("one_hour"), do: :one_hour
  defp parse_duration("one_day"), do: :one_day
  defp parse_duration("thirty_days"), do: :thirty_days
  defp parse_duration("ninety_days"), do: :ninety_days
  defp parse_duration(_), do: :once

  defp parse_scope("any_args"), do: :any_args
  defp parse_scope(_), do: :exact_args

  # Extract values via Keyword.fetch so the function doesn't depend on
  # the exact pair-count of `opts` — a previous shape mismatched the
  # caller's 3-key opts (`duration`, `scope`, `max_uses`) and crashed
  # the LV on every approve click.
  defp approval_flash(opts) do
    scope = Keyword.fetch!(opts, :scope)

    case Keyword.fetch!(opts, :duration) do
      :once ->
        "Approved for this call only."

      :one_hour ->
        "Approved. Standing grant active for the next hour (#{scope_label(scope)})."

      :one_day ->
        "Approved. Standing grant active for the next 24 hours (#{scope_label(scope)})."

      :thirty_days ->
        "Approved. Standing grant active for the next 30 days (#{scope_label(scope)}). Revoke from the agents page."

      :ninety_days ->
        "Approved. Standing grant active for the next 90 days (#{scope_label(scope)}). Revoke from the agents page."
    end
  end

  defp scope_label(:any_args), do: "any arguments"
  defp scope_label(_), do: "same arguments only"

  defp blank_or(""), do: nil
  defp blank_or(s), do: s

  # Rendering helper for "Requested by" / "Decided by". Prefers the
  # user's full name, falls back to email, then to a short UUID slice
  # if the user record is gone (deleted account), then to em-dash.
  defp user_label(%Emisar.Accounts.User{full_name: name}, _id)
       when is_binary(name) and name != "",
       do: name

  defp user_label(%Emisar.Accounts.User{email: email}, _id), do: email
  defp user_label(_, id) when is_binary(id), do: String.slice(id, 0, 8) <> "…"
  defp user_label(_, _), do: "—"

  # First 12 chars of a runner UUID + "…" trailer when one exists, or
  # an em-dash if the context didn't carry a runner_id at all. Kept as
  # a helper so the template stays single-expression — mixing a slice
  # and a ternary inline tripped the HEEx formatter into an unstable
  # whitespace fixed-point.
  defp truncated_runner_id(nil), do: "—"
  defp truncated_runner_id(id) when is_binary(id), do: String.slice(id, 0, 12) <> "…"

  # An action only leaves the queue when its runner is connected. The
  # decision panel surfaces this so an operator doesn't approve into a
  # dead runner and then wonder why the run never moved.
  defp runner_connection(%{runner: %{id: id, account_id: account_id}}),
    do: if(Runners.online?(account_id, id), do: :online, else: :offline)

  defp runner_connection(_), do: :unknown

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:approvals}
    >
      <:title>
        <.back_link navigate={~p"/app/approvals"}>Approvals</.back_link>
        Approval · <span class="font-mono text-base">{@request.context["action_id"] || "—"}</span>
      </:title>
      <%!-- Meta strip: at-a-glance facts. Status leads — same pattern
           as RunDetail / RunnerDetail — then action, runner,
           requester, when. --%>
      <.meta_strip cols={5}>
        <.meta_field label="Status">
          <.status_badge status={@request.status} />
        </.meta_field>
        <.meta_field label="Action">
          <span class="truncate font-mono text-zinc-200">
            {@request.context["action_id"] || "—"}
          </span>
        </.meta_field>
        <.meta_field label="Runner">
          <%= if @run && @run.runner do %>
            <span class="inline-flex min-w-0 items-center gap-1.5">
              <span
                class={[
                  "h-1.5 w-1.5 flex-none rounded-full",
                  if(@runner_connection == :online, do: "bg-emerald-400", else: "bg-zinc-600")
                ]}
                title={if(@runner_connection == :online, do: "Online", else: "Offline")}
              />
              <.link
                navigate={~p"/app/runners/#{@run.runner.id}"}
                class="truncate text-zinc-200 hover:text-indigo-300"
              >
                {@run.runner.name}
              </.link>
            </span>
          <% else %>
            <span class="truncate font-mono text-xs text-zinc-400">
              {truncated_runner_id(@request.context["runner_id"])}
            </span>
          <% end %>
        </.meta_field>
        <.meta_field label="Requested by">
          <span class="truncate text-zinc-200">
            {user_label(@requested_by, @request.requested_by_id)}
          </span>
        </.meta_field>
        <.meta_field label="When">
          <.local_time value={@request.requested_at} class="text-zinc-200" />
        </.meta_field>
      </.meta_strip>

      <div class="mt-6 grid grid-cols-1 gap-6 lg:grid-cols-[1fr_320px]">
        <%!-- Left: context — reason, policy, args, link to run --%>
        <div class="space-y-4">
          <section
            :if={@request.reason && @request.reason != ""}
            class="rounded-xl border border-zinc-900 bg-zinc-950/40 p-4"
          >
            <h3 class="text-xs font-semibold uppercase tracking-wider text-zinc-500">
              Operator's reason
            </h3>
            <p class="mt-2 whitespace-pre-wrap text-sm leading-relaxed text-zinc-200">
              {@request.reason}
            </p>
          </section>

          <section
            :if={@run && @run.policy_reason}
            class="rounded-xl border border-amber-500/30 bg-amber-500/[0.04] p-4"
          >
            <h3 class="flex items-center gap-2 text-xs font-semibold uppercase tracking-wider text-amber-200/70">
              <.icon name="hero-shield-exclamation" class="h-4 w-4 text-amber-300" />
              Why approval is required
            </h3>
            <p class="mt-2 text-sm leading-relaxed text-amber-100">{@run.policy_reason}</p>
            <div
              :if={@run.matched_rules && @run.matched_rules != []}
              class="mt-2 text-xs text-amber-200/70"
            >
              Matched rules: <span class="font-mono">{Enum.join(@run.matched_rules, ", ")}</span>
            </div>
          </section>

          <section
            :if={@run && @run.args && @run.args != %{}}
            class="overflow-hidden rounded-xl border border-zinc-900 bg-zinc-950/40"
          >
            <header class="flex items-center justify-between border-b border-zinc-900 px-4 py-2">
              <h3 class="text-xs font-semibold uppercase tracking-wider text-zinc-500">
                Arguments
              </h3>
              <span :if={@request.context["args_sha256"]} class="font-mono text-[11px] text-zinc-500">
                sha256:{String.slice(@request.context["args_sha256"], 0, 16)}…
              </span>
            </header>
            <pre class="max-h-64 overflow-auto bg-black/40 p-4 font-mono text-xs text-zinc-300">{format_json(@run.args)}</pre>
          </section>

          <div :if={@run}>
            <.link
              navigate={~p"/app/runs/#{@run.id}"}
              class="inline-flex items-center gap-1 text-sm text-indigo-400 hover:text-indigo-300"
            >
              View run details <.icon name="hero-arrow-right" class="h-3.5 w-3.5" />
            </.link>
          </div>
        </div>

        <%!-- Right: decision panel — sticky on desktop so it stays in
             reach when scanning a long args/reason. --%>
        <aside class="lg:sticky lg:top-6 lg:self-start">
          <%= if @request.status == "pending" do %>
            <.decision_panel
              can_decide?={Permissions.can?(assigns, :decide_approval)}
              grant_duration={@grant_duration}
              runner_state={@runner_connection}
            />
          <% else %>
            <section class="rounded-xl border border-zinc-900 bg-zinc-950/40 p-5">
              <h3 class="text-sm font-semibold text-zinc-100">Decision history</h3>
              <dl class="mt-3 space-y-2 text-sm">
                <.kv label="Status"><.status_badge status={@request.status} /></.kv>
                <.kv label="Decided"><.local_time value={@request.decided_at} /></.kv>
                <.kv label="By">{user_label(@decided_by, @request.decided_by_id)}</.kv>
                <.kv :if={@request.decision_reason && @request.decision_reason != ""} label="Reason">
                  <span class="text-xs text-zinc-300">{@request.decision_reason}</span>
                </.kv>
              </dl>
            </section>
          <% end %>
        </aside>
      </div>
    </.dashboard_shell>
    """
  end

  attr :can_decide?, :boolean, required: true
  # Drives the reuse-window UI: the Match / Limit-to fields only show
  # once a real grant is being minted (duration != "once"). Defaulted so
  # a caller that forgets to thread it through can't crash the panel.
  attr :grant_duration, :string, default: "once"
  # Connection state of the target runner (:online | :offline | :unknown)
  # so the operator knows whether an approval will actually dispatch.
  attr :runner_state, :atom, default: :unknown

  defp decision_panel(assigns) do
    ~H"""
    <section class="rounded-xl border border-zinc-900 bg-zinc-950/60 p-5">
      <h3 class="text-sm font-semibold text-zinc-100">Decide</h3>
      <p class="mt-1 text-xs text-zinc-500">Logged to the audit trail.</p>

      <div
        :if={@runner_state == :offline}
        class="mt-4 flex items-start gap-2 rounded-lg border border-amber-500/30 bg-amber-500/[0.06] p-3 text-xs text-amber-200"
      >
        <.icon name="hero-signal-slash" class="mt-0.5 h-4 w-4 flex-none text-amber-300" />
        <span>
          This runner is offline. You can still approve — the action queues and runs once the
          runner reconnects, or expires if it doesn't.
        </span>
      </div>

      <%= if @can_decide? do %>
        <%!-- Approve form. Default state = one-shot ("just this
             call") which doesn't create a grant. Reuse-window UI
             is collapsed behind a checkbox so the common path
             is one click of the green button. --%>
        <form phx-submit="approve" phx-change="grant_form_changed" class="mt-4 space-y-4">
          <textarea
            name="reason"
            rows="2"
            placeholder="Note (optional)"
            class="w-full resize-none rounded-lg border-0 bg-zinc-900 px-3 py-2 text-sm text-zinc-200 ring-1 ring-zinc-800 placeholder:text-zinc-600 focus:ring-indigo-500"
          ></textarea>

          <details class="group rounded-lg border border-zinc-800 bg-zinc-950/60 p-3">
            <summary class="flex cursor-pointer items-center justify-between text-xs text-zinc-300 hover:text-zinc-100">
              <span class="flex items-center gap-2">
                <.icon name="hero-clock" class="h-3.5 w-3.5 text-zinc-400" />
                Allow the LLM to reuse this approval
              </span>
              <.icon
                name="hero-chevron-down"
                class="h-4 w-4 text-zinc-500 transition group-open:rotate-180"
              />
            </summary>
            <div class="mt-3 space-y-3">
              <div>
                <label class="block text-[10px] font-semibold uppercase tracking-wider text-zinc-500">
                  For
                </label>
                <select
                  name="duration"
                  class="mt-1 w-full rounded-lg border-0 bg-zinc-900 px-3 py-2 text-sm text-zinc-200 ring-1 ring-zinc-800 focus:ring-indigo-500"
                >
                  <option value="once">Just this call (no grant)</option>
                  <option value="one_hour">Next 1 hour</option>
                  <option value="one_day">Next 24 hours</option>
                  <option value="thirty_days">Next 30 days</option>
                  <option value="ninety_days">Next 90 days</option>
                </select>
              </div>
              <%!-- Match / Limit-to only matter when an actual grant is
                   being minted. With duration="once" no grant is created,
                   so showing these fields was asking the operator to
                   configure parameters that get discarded. The form's
                   phx-change handler tracks duration → re-renders this
                   block. --%>
              <div :if={@grant_duration != "once"}>
                <label class="block text-[10px] font-semibold uppercase tracking-wider text-zinc-500">
                  Match
                </label>
                <select
                  name="scope"
                  class="mt-1 w-full rounded-lg border-0 bg-zinc-900 px-3 py-2 text-sm text-zinc-200 ring-1 ring-zinc-800 focus:ring-indigo-500"
                >
                  <option value="exact_args">Same arguments only</option>
                  <option value="any_args">Any arguments for this action</option>
                </select>
              </div>
              <div :if={@grant_duration != "once"}>
                <label class="block text-[10px] font-semibold uppercase tracking-wider text-zinc-500">
                  Limit to (optional)
                </label>
                <input
                  type="number"
                  name="max_uses"
                  min="1"
                  placeholder="unlimited"
                  class="mt-1 w-full rounded-lg border-0 bg-zinc-900 px-3 py-2 text-sm text-zinc-200 ring-1 ring-zinc-800 placeholder:text-zinc-600 focus:ring-indigo-500"
                />
                <p class="mt-1 text-[11px] leading-relaxed text-zinc-500">
                  Cap how many times this grant can be used within the window. Leave blank for unlimited.
                  Grants are reviewable + revocable on the <.link
                    navigate={~p"/app/approvals"}
                    class="text-indigo-400 hover:text-indigo-300"
                  >
                    approvals page
                  </.link>.
                </p>
              </div>
            </div>
          </details>

          <button class="flex w-full items-center justify-center gap-2 rounded-lg bg-emerald-500 px-3 py-2.5 text-sm font-semibold text-zinc-950 hover:bg-emerald-400">
            <.icon name="hero-check" class="h-4 w-4" /> Approve and send
          </button>
        </form>

        <form phx-submit="deny" class="mt-3">
          <button class="flex w-full items-center justify-center gap-2 rounded-lg border border-rose-500/40 px-3 py-2.5 text-sm font-medium text-rose-200 hover:bg-rose-500/10">
            <.icon name="hero-x-mark" class="h-4 w-4" /> Deny
          </button>
        </form>
      <% else %>
        <p class="mt-4 rounded-lg bg-zinc-900/60 p-4 text-xs text-zinc-400">
          Viewers can't decide approvals.
        </p>
      <% end %>
    </section>
    """
  end
end
