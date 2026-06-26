defmodule EmisarWeb.UserSignUpLive do
  use EmisarWeb, :live_view

  alias Emisar.{Accounts, Auth, Mailers, Users}

  def mount(_params, _session, socket) do
    changeset = Users.change_user(%Emisar.Users.User{})

    {:ok,
     socket
     |> assign(:page_title, "Create an account")
     |> assign(:trigger_submit, false)
     |> assign(:account_name, "")
     |> assign(:account_name_error, nil)
     |> assign_form(changeset)}
  end

  def render(assigns) do
    ~H"""
    <.auth_layout title="Start your free workspace">
      <p class="mb-6 text-sm text-zinc-400">
        Free plan: 3 runners, 7-day audit retention, single user. No credit card.
        There's no password to set — we'll email you a one-time sign-in link.
      </p>

      <%!-- On a successful save we flip `trigger_submit` and the form POSTs its
           email to the magic-link request, so the new owner gets a sign-in
           link immediately (no password, no re-typing their email). --%>
      <.simple_form
        for={@form}
        id="registration_form"
        phx-submit="save"
        phx-change="validate"
        phx-trigger-action={@trigger_submit}
        action={~p"/sign_in/magic/start"}
        method="post"
      >
        <.input field={@form[:full_name]} type="text" label="Your name" required />
        <.input field={@form[:email]} type="email" label="Work email" autocomplete="email" required />
        <.input
          name="account_name"
          value={@account_name}
          type="text"
          label="Team or company name"
          errors={if @account_name_error, do: [@account_name_error], else: []}
          required
        />

        <:actions>
          <.button phx-disable-with="Creating..." class="w-full">
            Create account <span aria-hidden="true">→</span>
          </.button>
        </:actions>
      </.simple_form>

      <p class="mt-6 text-center text-sm text-zinc-400">
        Already have an account?
        <.link href={~p"/sign_in"} class="font-medium text-brand-400 hover:text-brand-300">
          Sign in
        </.link>
      </p>
    </.auth_layout>
    """
  end

  def handle_event("validate", %{"user" => params} = all, socket) do
    changeset =
      %Emisar.Users.User{}
      |> Users.change_user(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:account_name, all["account_name"] || socket.assigns.account_name)
     |> assign(:account_name_error, nil)
     |> assign_form(changeset)}
  end

  def handle_event("save", %{"user" => user_params} = all, socket) do
    account_name = String.trim(all["account_name"] || "")

    if account_name == "" do
      # Inline under the field (it's a hand-rolled input, not a changeset
      # field) — matches every other form's inline-error behaviour, not a flash.
      {:noreply,
       socket
       |> assign(:account_name, "")
       |> assign(:account_name_error, "Tell us what to call your workspace.")}
    else
      do_save(socket, user_params, account_name)
    end
  end

  defp do_save(socket, user_params, account_name) do
    case Users.register_user(user_params) do
      {:ok, user} ->
        case Accounts.create_account_with_owner(
               %{
                 name: account_name,
                 slug: Accounts.suggest_unique_slug(account_name)
               },
               user
             ) do
          {:ok, account} ->
            :ok = Auth.deliver_confirmation_instructions(user)
            # Hand the owner their team's branded sign-in link to share — a
            # second, informational email (the confirmation above is the
            # action-required one).
            Mailers.UserNotifier.deliver_welcome(user, account)

            # Flip trigger_submit → the form POSTs the email to magic_link_start,
            # which mails the sign-in link + lands them on "check your email".
            {:noreply,
             socket
             |> assign(:trigger_submit, true)
             |> assign_form(Users.change_user(user))}

          {:error, _reason} ->
            # Rare race: the user row committed but the workspace didn't. Still
            # send the confirmation email so the user can verify and sign in — the
            # onboarding redirect then walks them through creating a workspace.
            :ok = Auth.deliver_confirmation_instructions(user)

            {:noreply,
             socket
             |> put_flash(
               :info,
               "Your account is ready — check your email for a confirmation link, then " <>
                 "sign in and we'll help you finish setting up your workspace."
             )
             |> push_navigate(to: ~p"/sign_in/magic")}
        end

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset),
    do: assign(socket, :form, to_form(changeset, as: "user"))
end
