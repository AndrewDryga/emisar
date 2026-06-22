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
      </p>

      <.simple_form
        for={@form}
        id="registration_form"
        phx-submit="save"
        phx-change="validate"
        phx-trigger-action={@trigger_submit}
        action={~p"/sign_in?_action=registered"}
        method="post"
      >
        <.input field={@form[:full_name]} type="text" label="Your name" required />
        <.input field={@form[:email]} type="email" label="Work email" autocomplete="email" required />
        <.input
          field={@form[:password]}
          type="password"
          label="Password"
          autocomplete="new-password"
          minlength="12"
          required
        />
        <%!-- Live strength tick — phx-change already streams the value, so
             flip the hint to a ✓ once it clears the 12-char floor. --%>
        <% password_ok? = String.length(@form[:password].value || "") >= 12 %>
        <p class={["text-xs", if(password_ok?, do: "text-brand-400", else: "text-zinc-500")]}>
          {if password_ok?,
            do: "✓ At least 12 characters.",
            else: "Use at least 12 characters. Mix in numbers or symbols for extra safety."}
        </p>
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

            {:noreply,
             socket
             |> assign(:trigger_submit, true)
             |> assign_form(Users.change_user(user))}

          {:error, _reason} ->
            # Rare race: the user row committed but the workspace didn't. Still
            # send the confirmation email (the success branch does too) so the
            # user can verify and sign in — the onboarding redirect then walks
            # them through creating a workspace. Without this they'd be a
            # confirmed-account orphan with no link and no way to verify.
            :ok = Auth.deliver_confirmation_instructions(user)

            {:noreply,
             socket
             |> put_flash(
               :info,
               "Your account is ready — check your email for a confirmation link. " <>
                 "Confirm it and sign in, and we'll help you finish setting up your workspace."
             )
             |> push_navigate(to: ~p"/sign_in")}
        end

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset),
    do: assign(socket, :form, to_form(changeset, as: "user"))
end
