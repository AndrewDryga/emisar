defmodule EmisarWeb.OnboardingLive do
  @moduledoc """
  Workspace creation flow. Shown when a user has no membership yet
  (first-run signup) AND from the in-app workspace switcher ("Create
  new workspace"). Live validation accompanies a native HTTP submission:
  creation can retire an old SSO route and disconnect this socket, so the
  committing response and new-workspace redirect must not depend on it.
  """
  use EmisarWeb, :live_view
  alias Emisar.{Accounts, Auth}
  alias EmisarWeb.{BillingIntent, LiveForm}
  on_mount {EmisarWeb.UserAuth, :mount_current_user}

  # The live_session only mounts the current user; it does not require one. A
  # signed-out visitor got the full setup form, and submitting it reached
  # create_account_with_owner_from_name/2 without an actor, so the socket died with no
  # explanation. Send them to sign in instead of rendering a form that cannot
  # succeed.
  def mount(_params, session, socket) do
    if socket.assigns[:current_user] do
      if Auth.personal_session?(socket.assigns.current_auth) do
        {billing_intent, billing_choice} = billing_choice(session["billing_intent"])

        {:ok,
         socket
         |> assign(:page_title, "Create your workspace")
         |> assign(:billing_intent, billing_intent)
         |> assign(:billing_choice, billing_choice)
         |> assign(:trigger_submit, false)
         |> assign(:form, initial_form(session))}
      else
        {:ok,
         socket
         |> redirect(to: ~p"/session/recover?reason=personal_required")}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, "You must sign in to set up a workspace.")
       |> redirect(to: ~p"/sign_in")}
    end
  end

  def render(assigns) do
    ~H"""
    <.auth_layout title="Create your workspace">
      <p :if={is_nil(@billing_choice)} class="mb-6 text-sm text-zinc-400">
        Give your workspace a name. Next, connect a runner and an AI agent to run your first action.
      </p>
      <.selected_plan :if={@billing_choice} cycle={@billing_choice.cycle} class="mb-6">
        Create this workspace on Free, then review the Team upgrade. Nothing is charged now.
      </.selected_plan>

      <.simple_form
        for={@form}
        id="onboarding_form"
        phx-change="validate"
        phx-submit="create"
        phx-trigger-action={@trigger_submit}
        action={~p"/onboarding"}
        method="post"
      >
        <.input
          field={@form[:name]}
          type="text"
          label="Workspace name"
          autocomplete="organization"
          placeholder="Acme Corp"
          required
        />
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
        Starts on the Free plan: 3 runners, 1 seat, 7-day audit retention. You can upgrade any time.
      </p>
      <.auth_footer_link href={~p"/sign_out"} method="delete">
        Sign out
      </.auth_footer_link>
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

  def handle_event("create", %{"account" => params}, socket) do
    # Unload the socket and submit over HTTP before any operation that can
    # disconnect it. The controller rechecks proof and all creation constraints.
    changeset = Accounts.change_account(%Accounts.Account{}, params)

    {:noreply,
     socket
     |> assign_form(%{changeset | action: :validate})
     # Slug creation belongs to the HTTP transaction; this form edits only name.
     |> assign(:trigger_submit, is_nil(changeset.errors[:name]))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset),
    do: assign(socket, :form, to_form(changeset, as: "account"))

  defp initial_form(%{"onboarding_params" => %{} = params} = session) do
    to_form(params, as: "account", errors: session["onboarding_errors"] || [], action: :validate)
  end

  defp initial_form(_session) do
    %Accounts.Account{}
    |> Accounts.change_account(%{"plan" => "free"})
    |> to_form(as: "account")
  end

  defp billing_choice(token) do
    case BillingIntent.verify(token) do
      {:ok, choice} -> {token, choice}
      {:error, :invalid} -> {nil, nil}
    end
  end
end
