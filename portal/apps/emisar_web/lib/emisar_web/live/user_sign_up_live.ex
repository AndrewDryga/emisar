defmodule EmisarWeb.UserSignUpLive do
  use EmisarWeb, :live_view
  alias Emisar.{Accounts, Throttle, Users}
  alias EmisarWeb.{BillingIntent, LiveForm, RegistrationHandoff, RequestContext}

  @signup_limit 20
  @signup_window_ms 60 * 60_000

  # The landing page's CTA collects a work email and GETs here with it; carry it
  # into the form so the operator doesn't retype what they just typed.
  def mount(params, _session, socket) do
    changeset = Users.change_user(%Emisar.Users.User{}, Map.take(params, ["email"]))
    {billing_intent, billing_choice} = billing_choice(params["billing_intent"])

    {:ok,
     socket
     |> assign(:page_title, "Create your workspace")
     |> assign(:billing_intent, billing_intent)
     |> assign(:billing_choice, billing_choice)
     |> assign(:trigger_submit, false)
     |> assign(:account_name, "")
     |> assign(:account_name_error, nil)
     |> assign(:registration_handoff, nil)
     |> assign(:request_context, RequestContext.from_socket(socket))
     |> assign_form(changeset)}
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

      <%!-- On a successful save we flip `trigger_submit` and the form POSTs its
           email to the magic-link request, so the new owner gets a sign-in
           link immediately (no password, no re-typing their email). The magic
           link confirms the email address when used, so signup itself stays
           quiet and the operator gets one email, not three. --%>
      <.simple_form
        for={@form}
        id="registration_form"
        phx-submit="save"
        phx-change="validate"
        phx-trigger-action={@trigger_submit}
        action={~p"/sign_in/magic/start"}
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
        <%!-- Explicit id: account_name isn't a @form field (it's a standalone
             param), so it needs an id for its <label for> to associate — a screen
             reader can't otherwise name the field (UI-005). --%>
        <.input
          name="account_name"
          id="account_name"
          value={@account_name}
          type="text"
          label="Team or company name"
          autocomplete="organization"
          errors={if @account_name_error, do: [@account_name_error], else: []}
          required
        />

        <%!-- The auth mechanism, stated where it happens (the CTA) — not
             mixed into the plan facts above. --%>
        <p class="text-xs leading-relaxed text-zinc-400">
          No password to set — we'll email you a one-time sign-in link and a 6-character code.
        </p>

        <%!-- Carries the workspace/profile intent to the inbox-proof factor.
             Existing-email submissions carry an equal-shaped decoy, so this
             client-visible value never reveals whether registration can resume. --%>
        <input
          :if={@billing_intent}
          type="hidden"
          name="billing_intent"
          value={@billing_intent}
        />

        <input
          :if={@registration_handoff}
          type="hidden"
          name="registration_handoff"
          value={@registration_handoff}
        />

        <:actions>
          <.button phx-disable-with="Creating..." class="w-full">
            Create account <span aria-hidden="true">→</span>
          </.button>
        </:actions>
      </.simple_form>

      <%!-- Consent at the point of account creation — footer links don't
           read as agreement on a trust product. --%>
      <p class="mt-3 text-center text-xs text-zinc-400">
        By creating an account you agree to the
        <.link href={~p"/terms"} class="text-zinc-400 underline hover:text-zinc-200">Terms</.link>
        and <.link href={~p"/privacy"} class="text-zinc-400 underline hover:text-zinc-200">
          Privacy Policy</.link>.
      </p>

      <.auth_footer_link href={~p"/sign_in"}>
        <:lead>Already have an account?</:lead>
        Sign in
      </.auth_footer_link>
    </.auth_layout>
    """
  end

  def handle_event("validate", %{"user" => params} = all, socket) do
    changeset =
      %Emisar.Users.User{}
      |> Users.change_user(params)
      |> LiveForm.on_change(all)

    {:noreply,
     socket
     |> assign(:account_name, all["account_name"] || socket.assigns.account_name)
     |> assign(:account_name_error, nil)
     |> assign_form(changeset)}
  end

  def handle_event("save", %{"user" => user_params} = all, socket) do
    case Throttle.check(
           "sign_up",
           socket.assigns.request_context.ip_address,
           @signup_limit,
           @signup_window_ms
         ) do
      :ok -> handle_save(socket, user_params, all)
      {:error, :rate_limited} -> signup_rate_limited(socket)
    end
  end

  defp handle_save(socket, user_params, all) do
    account_name = String.trim(all["account_name"] || "")

    socket =
      socket
      |> assign(:account_name, account_name)
      |> assign(:account_name_error, nil)

    if account_name == "" do
      # Inline under the field (it's a hand-rolled input, not a changeset
      # field) — matches every other form's inline-error behaviour, not a flash.
      {:noreply, assign(socket, :account_name_error, "Tell us what to call your workspace.")}
    else
      do_save(socket, user_params, account_name)
    end
  end

  defp do_save(socket, user_params, account_name) do
    full_name = user_params["full_name"]

    account_attrs = %{
      name: account_name,
      slug: Accounts.suggest_unique_slug(account_name)
    }

    case Accounts.begin_owner_registration(user_params, account_attrs) do
      {:ok, user} ->
        arm_magic_link_post(
          socket,
          user_params,
          RegistrationHandoff.sign(user.id, account_name, full_name)
        )

      {:error, :email_taken} ->
        arm_magic_link_post(
          socket,
          user_params,
          RegistrationHandoff.decoy(account_name, full_name)
        )

      {:error, {:user, changeset}} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, {:account, changeset}} ->
        {:noreply,
         socket
         |> assign(:account_name_error, account_name_error(changeset))
         |> assign_form(Users.change_user(%Emisar.Users.User{}, user_params))}

      # The owner membership is fixed by this flow, so a failure here is ours,
      # not something the operator can retype their way out of.
      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "We couldn't finish setting up your workspace. Try again.")
         |> assign_form(Users.change_user(%Emisar.Users.User{}, user_params))}
    end
  end

  # Both a new registration and an existing email submit the same form with a
  # same-shaped opaque handoff. Only the handoff whose signed id matches the
  # resumable zero-membership user carries registration authority downstream.
  defp arm_magic_link_post(socket, user_params, handoff) do
    {:noreply,
     socket
     |> assign(:trigger_submit, true)
     |> assign(:registration_handoff, handoff)
     |> assign_form(Users.change_user(%Emisar.Users.User{}, user_params))}
  end

  defp signup_rate_limited(socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Too many signup attempts. Wait a while, then try again.")
     |> assign(:trigger_submit, false)}
  end

  # The workspace name is a standalone param, not a form field, so its rejection
  # arrives as the account changeset. The slug is derived from the name, so a
  # name that validated yet produced an unusable slug is still a name problem
  # to the operator.
  defp account_name_error(%Ecto.Changeset{} = changeset) do
    case changeset.errors[:name] || changeset.errors[:slug] do
      nil -> "Pick a different workspace name."
      error -> translate_error(error)
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset),
    do: assign(socket, :form, to_form(changeset, as: "user"))

  defp billing_choice(token) do
    case BillingIntent.verify(token) do
      {:ok, choice} -> {token, choice}
      {:error, :invalid} -> {nil, nil}
    end
  end
end
