defmodule EmisarWeb.OnboardingLive do
  @moduledoc """
  Workspace creation flow. Shown when a user has no membership yet
  (first-run signup) AND from the in-app workspace switcher ("Create
  new workspace"). After the workspace is created we trigger a real
  POST to `AccountSwitchController` so the next-request session gets
  pinned to the new tenant — otherwise the previous session-pinned
  account would persist and the user would land back in the old
  workspace after the redirect.
  """
  use EmisarWeb, :live_view
  alias Emisar.Accounts
  alias EmisarWeb.{BillingIntent, LiveForm}

  # The live_session only mounts the current user; it does not require one. A
  # signed-out visitor got the full setup form, and submitting it reached
  # create_account_with_owner_from_name/2 with a nil user — whose only clause
  # requires a %User{} — so the socket died with a FunctionClauseError and no
  # explanation. Send them to sign in instead of rendering a form that cannot
  # succeed.
  def mount(params, session, socket) do
    if socket.assigns[:current_user] do
      {billing_intent, billing_choice} =
        billing_choice(params["billing_intent"] || session["billing_intent"])

      {:ok,
       socket
       |> assign(:page_title, "Set up your workspace")
       |> assign(:billing_intent, billing_intent)
       |> assign(:billing_choice, billing_choice)
       |> assign(:trigger_submit, false)
       |> assign(:created_account_id, "")
       |> assign_form(Accounts.change_account(%Accounts.Account{}, %{"plan" => "free"}))}
    else
      {:ok,
       socket
       |> put_flash(:error, "You must sign in to set up a workspace.")
       |> redirect(to: ~p"/sign_in")}
    end
  end

  def render(assigns) do
    ~H"""
    <.auth_layout title="Set up your workspace">
      <p :if={is_nil(@billing_choice)} class="mb-6 text-sm text-zinc-400">
        One quick step. You'll invite members and connect runners next.
      </p>
      <p :if={@billing_choice} class="mb-6 text-sm leading-relaxed text-zinc-400">
        <span class="font-medium text-zinc-200">
          Team checkout · {cycle_label(@billing_choice.cycle)}.
        </span>
        Create this workspace on Free, then review Team billing. Nothing is charged now.
      </p>

      <.simple_form
        for={@form}
        id="onboarding_form"
        phx-change="validate"
        phx-submit="create"
        phx-trigger-action={@trigger_submit}
        action={~p"/app/accounts/switch"}
        method="post"
      >
        <.input
          field={@form[:name]}
          type="text"
          label="What's your team or company called?"
          autocomplete="organization"
          placeholder="Acme Corp"
          required
        />
        <input type="hidden" name="account_id" value={@created_account_id} />
        <input
          :if={@billing_intent}
          type="hidden"
          name="billing_intent"
          value={@billing_intent}
        />

        <:actions>
          <.button class="w-full" phx-disable-with="Creating...">
            Create workspace <span aria-hidden="true">→</span>
          </.button>
        </:actions>
      </.simple_form>

      <p :if={is_nil(@billing_choice)} class="mt-6 text-xs text-zinc-400">
        Starts on the Free plan: 3 runners, 1 user, 7-day audit retention. You can upgrade any time.
      </p>
    </.auth_layout>
    """
  end

  def handle_event("validate", %{"account" => params} = event, socket) do
    changeset =
      %Accounts.Account{}
      |> Accounts.change_account(params)
      |> LiveForm.on_change(event)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("create", %{"account" => %{"name" => name}}, socket) do
    user = socket.assigns.current_user

    case Accounts.create_account_with_owner_from_name(name, user) do
      {:ok, account} ->
        # `trigger_submit: true` fires the form's `action=` POST in the
        # next browser tick — `AccountSwitchController` validates the
        # just-created membership and pins it in the session before the
        # redirect to /app.
        {:noreply,
         socket
         |> assign(:created_account_id, account.id)
         |> assign(:trigger_submit, true)}

      # A blank/invalid name renders inline on the name field; Accounts already
      # moved a derived-slug error onto :name, the only field this form has.
      # Membership and policy changesets do not belong to this form.
      {:error, %Ecto.Changeset{data: %Accounts.Account{}} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, _reason} ->
        changeset = Accounts.change_account(%Accounts.Account{}, %{"name" => name})

        {:noreply,
         socket
         |> assign_form(changeset)
         |> put_flash(:error, "Couldn't create this workspace. Try again.")}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset),
    do: assign(socket, :form, to_form(changeset, as: "account"))

  defp billing_choice(token) do
    case BillingIntent.verify(token) do
      {:ok, choice} -> {token, choice}
      {:error, :invalid} -> {nil, nil}
    end
  end

  defp cycle_label(:month), do: "Monthly billing"
  defp cycle_label(:year), do: "Annual billing"
end
