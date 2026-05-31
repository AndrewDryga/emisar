defmodule EmisarWeb.OnboardingLive do
  @moduledoc """
  First-time setup flow. Shown when a user has no membership yet:
  pick an org name → create account on Free plan → land in dashboard.
  """
  use EmisarWeb, :live_view

  alias Emisar.Accounts

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Set up your workspace")
     |> assign(:form, to_form(%{"name" => "", "plan" => "free"}, as: "account"))}
  end

  def render(assigns) do
    ~H"""
    <div class="mx-auto flex min-h-screen max-w-2xl flex-col items-center justify-center px-6 py-12">
      <div class="mb-10">
        <.brand size={:md} />
      </div>

      <h1 class="text-3xl font-bold tracking-tight">Set up your workspace</h1>
      <p class="mt-2 text-center text-zinc-400">
        One quick step. You'll invite teammates and connect runners next.
      </p>

      <.card class="mt-10 w-full" padding="p-8">
        <.simple_form for={@form} id="onboarding_form" phx-submit="create">
          <.input
            field={@form[:name]}
            type="text"
            label="What's your team or company called?"
            placeholder="Acme Corp"
            required
          />

          <:actions>
            <.button class="w-full" phx-disable-with="Creating...">
              Create workspace <span aria-hidden="true">→</span>
            </.button>
          </:actions>
        </.simple_form>
      </.card>

      <p class="mt-6 text-xs text-zinc-500">
        Starts on the Free plan: 3 runners, 1 user, 7-day audit retention. You can upgrade any time.
      </p>
    </div>
    """
  end

  def handle_event("create", %{"account" => %{"name" => name}}, socket) do
    user = socket.assigns.current_user

    case Accounts.create_account_with_owner(
           %{name: name, slug: Accounts.suggest_unique_slug(name), plan: "free"},
           user
         ) do
      {:ok, _account} ->
        {:noreply, push_navigate(socket, to: ~p"/app")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Unable to create. Try a different name.")}
    end
  end
end
