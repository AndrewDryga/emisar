defmodule EmisarWeb.UserSignUpLive do
  @moduledoc """
  Self-serve sign-up: the owner's name and address and the workspace's name.
  The form validates here, then posts to `UserSessionController.sign_up_start`,
  which sends a code to the address and keeps the intent on it server-side.
  Nothing — no workspace, Member or slug — exists until that code comes back in
  this browser.
  """
  use EmisarWeb, :live_view
  alias Emisar.Accounts
  alias EmisarWeb.{BillingIntent, LiveForm}

  # The landing page's CTA collects a work email and GETs here with it; carry it
  # into the form so the operator doesn't retype what they just typed.
  def mount(params, _session, socket) do
    {billing_intent, billing_choice} = billing_choice(params["billing_intent"])

    {:ok,
     socket
     |> assign(:page_title, "Create your workspace")
     |> assign(:billing_intent, billing_intent)
     |> assign(:billing_choice, billing_choice)
     |> assign(:trigger_submit, false)
     |> assign_form(Accounts.change_sign_up(Map.take(params, ["email"])))}
  end

  def render(assigns) do
    ~H"""
    <.auth_layout title="Create your workspace">
      <p :if={is_nil(@billing_choice)} class="mb-6 text-sm text-zinc-400">
        Free plan: 3 runners, 7-day audit retention, 1 seat. No credit card.
      </p>
      <.selected_plan :if={@billing_choice} cycle={@billing_choice.cycle} class="mb-6">
        Create your workspace and verify your email. Review the price before you pay.
      </.selected_plan>

      <%!-- A valid submission flips `trigger_submit` and the form POSTs to
           sign-up, which emails a sign-in link and a 6-character code; using
           either in this browser proves the address and creates the
           workspace, so the operator gets one email, not three. --%>
      <.simple_form
        for={@form}
        id="registration_form"
        phx-submit="save"
        phx-change="validate"
        phx-trigger-action={@trigger_submit}
        action={~p"/sign_up"}
        method="post"
      >
        <.input
          field={@form[:full_name]}
          type="text"
          label="Your name"
          autocomplete="name"
          required
        />
        <.input field={@form[:email]} type="email" label="Work email" autocomplete="email" required />
        <.input
          field={@form[:account_name]}
          type="text"
          label="Workspace name"
          autocomplete="organization"
          required
        />

        <%!-- The auth mechanism, stated where it happens (the CTA) — not
             mixed into the plan facts above. --%>
        <p class="text-xs leading-relaxed text-zinc-400">
          We'll email you a one-time sign-in link and a 6-character code to verify your email
          and finish creating your workspace.
        </p>

        <input
          :if={@billing_intent}
          type="hidden"
          name="billing_intent"
          value={@billing_intent}
        />

        <:actions>
          <.button phx-disable-with="Creating..." class="w-full">
            Create workspace
          </.button>
        </:actions>
      </.simple_form>

      <%!-- Consent at the point of account creation — footer links don't
           read as agreement on a trust product. --%>
      <p class="mt-3 text-center text-xs text-zinc-400">
        By creating a workspace you agree to the
        <.link href={~p"/terms"} class="text-zinc-400 underline hover:text-zinc-200">Terms</.link>
        and <.link href={~p"/privacy"} class="text-zinc-400 underline hover:text-zinc-200">
          Privacy Policy</.link>.
      </p>

      <.auth_footer_link href={~p"/sign_in"}>
        <:lead>Already use emisar?</:lead>
        Sign in
      </.auth_footer_link>
    </.auth_layout>
    """
  end

  def handle_event("validate", %{"sign_up" => params} = event, socket) when is_map(params) do
    changeset =
      params
      |> Accounts.change_sign_up()
      |> LiveForm.on_change(event)

    {:noreply, assign_form(socket, changeset)}
  end

  # Validation only — the workspace name must also derive a usable address — and
  # nothing is written: the POST it arms sends the code, under the server's
  # address and per-IP budgets.
  def handle_event("save", %{"sign_up" => params}, socket) when is_map(params) do
    case Accounts.validate_sign_up(params) do
      {:ok, _sign_up} ->
        {:noreply,
         socket
         |> assign(:trigger_submit, true)
         |> assign_form(Accounts.change_sign_up(params))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp assign_form(socket, %Ecto.Changeset{} = changeset),
    do: assign(socket, :form, to_form(changeset, as: "sign_up"))

  defp billing_choice(token) do
    case BillingIntent.verify(token) do
      {:ok, choice} -> {token, choice}
      {:error, :invalid} -> {nil, nil}
    end
  end
end
