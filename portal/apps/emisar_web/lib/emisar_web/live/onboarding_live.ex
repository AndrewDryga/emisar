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

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Set up your workspace")
     |> assign(:trigger_submit, false)
     |> assign(:created_account_id, "")
     |> assign_form(Accounts.change_account(%Accounts.Account{}, %{"plan" => "free"}))}
  end

  def render(assigns) do
    ~H"""
    <.auth_layout title="Set up your workspace">
      <p class="mb-6 text-sm text-zinc-400">
        One quick step. You'll invite members and connect runners next.
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
          placeholder="Acme Corp"
          required
        />
        <input type="hidden" name="account_id" value={@created_account_id} />

        <:actions>
          <.button class="w-full" phx-disable-with="Creating...">
            Create workspace <span aria-hidden="true">→</span>
          </.button>
        </:actions>
      </.simple_form>

      <p class="mt-6 text-xs text-zinc-500">
        Starts on the Free plan: 3 runners, 1 user, 7-day audit retention. You can upgrade any time.
      </p>
    </.auth_layout>
    """
  end

  def handle_event("validate", %{"account" => params}, socket) do
    changeset =
      %Accounts.Account{}
      |> Accounts.change_account(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("create", %{"account" => %{"name" => name}}, socket) do
    user = socket.assigns.current_user

    case Accounts.create_account_with_owner(
           %{name: name, slug: Accounts.suggest_unique_slug(name)},
           user
         ) do
      {:ok, account} ->
        # `trigger_submit: true` fires the form's `action=` POST in the
        # next browser tick — `AccountSwitchController` validates the
        # just-created membership and pins it in the session before the
        # redirect to /app.
        {:noreply,
         socket
         |> assign(:created_account_id, account.id)
         |> assign(:trigger_submit, true)}

      # A blank/invalid name renders inline on the name field; the slug is
      # derived from the name on submit, so surface its error on :name too —
      # otherwise a too-short name fails silently on a field with no input.
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, surface_slug_error_on_name(changeset))}
    end
  end

  # The form has only a :name input, but the slug is derived from the name. When
  # the name validated yet the derived slug didn't (a 1-2 char name yields a
  # too-short slug), copy the slug error onto :name so the operator sees why the
  # workspace wasn't created instead of a silent no-op.
  defp surface_slug_error_on_name(%Ecto.Changeset{} = changeset) do
    changeset = Map.put(changeset, :action, :insert)

    case {changeset.errors[:name], changeset.errors[:slug]} do
      {nil, {message, opts}} -> Ecto.Changeset.add_error(changeset, :name, message, opts)
      _ -> changeset
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset),
    do: assign(socket, :form, to_form(changeset, as: "account"))
end
