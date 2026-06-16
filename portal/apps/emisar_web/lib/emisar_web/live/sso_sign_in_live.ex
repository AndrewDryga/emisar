defmodule EmisarWeb.SSOSignInLive do
  use EmisarWeb, :live_view
  alias Emisar.SSO

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Single sign-on")
     |> assign_form(%{"email" => Phoenix.Flash.get(socket.assigns.flash, :email)})}
  end

  # `phx-change` only re-renders the field; the domain lookup happens on submit.
  def handle_event("validate", %{"sso" => params}, socket) do
    {:noreply, assign_form(socket, params)}
  end

  def handle_event("discover", %{"sso" => %{"email" => email}}, socket) do
    # Hand off to the begin-auth controller on a match (it stashes the OIDC
    # state in the session, so this is a full redirect, not a patch).
    with {:ok, domain} <- email_domain(email),
         {:ok, provider} <- SSO.fetch_enabled_provider_by_email_domain(domain) do
      {:noreply, redirect(socket, to: ~p"/sign_in/sso/#{provider.id}")}
    else
      :error ->
        flash_and_keep(socket, email, "Enter a work email like you@company.com.")

      {:error, :not_found} ->
        flash_and_keep(socket, email, "No single sign-on is configured for that email domain.")
    end
  end

  defp flash_and_keep(socket, email, message) do
    {:noreply, socket |> put_flash(:error, message) |> assign_form(%{"email" => email})}
  end

  # The domain after the "@". A bare/blank/@-less entry is rejected so we never
  # query with an empty domain.
  defp email_domain(email) do
    parts = email |> to_string() |> String.trim() |> String.split("@")

    case parts do
      [_local, domain] when domain != "" -> {:ok, domain}
      _ -> :error
    end
  end

  defp assign_form(socket, params), do: assign(socket, :form, to_form(params, as: "sso"))

  def render(assigns) do
    ~H"""
    <.auth_layout title="Single sign-on">
      <.simple_form for={@form} id="sso_form" phx-change="validate" phx-submit="discover">
        <p class="text-sm leading-relaxed text-zinc-400">
          Enter your work email and we'll send you to your organization's identity provider.
        </p>
        <.input
          field={@form[:email]}
          type="email"
          label="Work email"
          placeholder="you@company.com"
          autocomplete="email"
          required
        />

        <:actions>
          <.button phx-disable-with="Looking up…" class="w-full">
            Continue <span aria-hidden="true">→</span>
          </.button>
        </:actions>
      </.simple_form>

      <div class="mt-8 text-center text-sm">
        <.link href={~p"/sign_in"} class="font-medium text-indigo-400 hover:text-indigo-300">
          Back to sign in
        </.link>
      </div>
    </.auth_layout>
    """
  end
end
