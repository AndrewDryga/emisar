defmodule EmisarWeb.MagicLinkLive do
  use EmisarWeb, :live_view
  alias Emisar.Auth
  alias EmisarWeb.{MagicLinkHandoff, RegistrationHandoff, RequestContext, ReturnTo}

  # The email form POSTs to `UserSessionController.magic_link_start` (a controller,
  # because issuing the split token sets a signed nonce cookie a LiveView can't).
  # The typed code is verified HERE (handle_event/3) so a wrong code shows inline
  # with no reload; on a match we redirect to `:magic_link_complete` with a
  # short-lived, cookie-bound handoff that establishes the session.
  def mount(params, session, socket) do
    email = sent_to(session)
    correction_email = correction_email(session, email)

    {:ok,
     socket
     |> assign(:page_title, "Sign in via email")
     |> assign(:sent?, params["sent"] == "1")
     # Branded pages pass ?return_to=/app/<slug>; threaded into the POST as a
     # hidden field so the emailed link + the code path both land on that team.
     |> assign(:return_to, ReturnTo.app_path(params["return_to"]))
     # The address magic_link_start stashed in the session, so the "sent" page can
     # offer Resend without a retype. nil when the page is opened directly.
     |> assign(:email, email)
     # The code's expiry (ISO8601) magic_link_start stashed — the sent page counts
     # it down and disables the code form when it lapses. nil on direct nav.
     |> assign(:expires_at, session["magic_link_expires_at"])
     # The browser's nonce half + the token id magic_link_start stashed, so this
     # LiveView can verify the typed code (the nonce isn't JS-readable). nil on
     # direct nav / unknown email — which reads as the same inline error (no leak).
     |> assign(:token_id, session["magic_link_token_id"])
     |> assign(:nonce, session["magic_link_nonce"])
     |> assign(:registered?, session["magic_link_registered"] == true)
     |> assign(:registration_handoff, registration_handoff(session))
     |> assign(:correction_email, correction_email)
     |> assign(:correction_email_error, correction_email_error(session))
     |> assign(:request_context, RequestContext.from_socket(socket))
     |> assign(:code_error, nil)
     |> assign(:email_form, to_form(%{"email" => correction_email || ""}, as: "user"))
     |> assign(:code_form, to_form(%{"code" => ""}))}
  end

  # The typed code, aggregated by the CodeInput hook into the hidden `code` field.
  # A wrong/expired code stays on the page with an inline error at the boxes —
  # never a redirect to a far-off flash. A verified code hands off to the
  # controller to set the session cookie (a LiveView can't set it). A nil
  # token_id/nonce (direct nav / unknown email) reads as the same inline error.
  def handle_event("verify_code", %{"code" => code}, socket) do
    %{token_id: token_id, nonce: nonce, request_context: context} = socket.assigns
    code = code |> to_string() |> String.trim() |> String.upcase()

    with true <- is_binary(token_id) and is_binary(nonce),
         {:ok, user} <- Auth.verify_magic_link(token_id, code, nonce, context) do
      handoff = MagicLinkHandoff.sign(user.id, socket.assigns.registered?, token_id)
      {:noreply, redirect(socket, to: ~p"/sign_in/magic/complete?#{[handoff: handoff]}")}
    else
      _ ->
        {:noreply,
         assign(
           socket,
           :code_error,
           "That code didn't match or has expired. Check it and try again, or resend below."
         )}
    end
  end

  defp sent_to(session) do
    case session["magic_link_email"] do
      email when is_binary(email) and email != "" -> email
      _ -> nil
    end
  end

  defp registration_handoff(%{"magic_link_registration_user_id" => user_id})
       when is_binary(user_id),
       do: RegistrationHandoff.sign(user_id)

  defp registration_handoff(_session), do: nil

  defp correction_email(session, email) do
    case session["magic_email_attempt"] do
      attempted when is_binary(attempted) and attempted != "" -> attempted
      _ -> email
    end
  end

  defp correction_email_error(%{"magic_email_error" => error}) when is_binary(error), do: error
  defp correction_email_error(_session), do: nil

  def render(assigns) do
    ~H"""
    <.auth_layout title="Sign in via email">
      <%= if @sent? do %>
        <.callout tone={:brand} icon="hero-envelope" title="Check your inbox.">
          <p :if={@email} class="mt-1.5">
            We emailed a sign-in link and a 6-character code to <code class="font-mono text-brand-100">{@email}</code>. Enter
            the code here, or open the link from <em>this same browser</em>. Both expire in
            15 minutes.
          </p>
          <p :if={!@email} class="mt-1.5">
            We emailed a sign-in link and a 6-character code. Enter the code here, or open the
            link from <em>this same browser</em>. Both expire in 15 minutes.
          </p>
          <%!-- MagicCodeExpiry fills this with a live "Code expires in M:SS"; on lapse it
                swaps to an "expired — resend" note and disables #code-submit, so a dead
                code can't be sent and the resend button below is the obvious next step. --%>
          <p
            :if={@expires_at}
            id="code-expiry"
            phx-hook="MagicCodeExpiry"
            data-expires-at={@expires_at}
            data-disable="code-submit"
            class="mt-3 text-xs font-medium text-brand-300/80"
          >
          </p>
        </.callout>

        <.simple_form for={@code_form} phx-submit="verify_code" class="mt-5">
          <.code_input id="magic-code" name="code" label="Sign-in code" error={@code_error} />
          <:actions>
            <.button id="code-submit" class="w-full">
              Sign in <span aria-hidden="true">→</span>
            </.button>
          </:actions>
        </.simple_form>

        <%!-- Resend: a secondary button the ResendCooldown hook disables for a
              short countdown ("Resend in 0:29") so an operator can't hammer the
              send, then re-enables. The server throttle (5 / 15 min) is the real
              limit and surfaces a clear flash when hit. --%>
        <.form
          :if={@email}
          for={%{}}
          action={~p"/sign_in/magic/start"}
          method="post"
          class="mt-3"
        >
          <input type="hidden" name="user[email]" value={@email} />
          <input type="hidden" name="return_to" value={@return_to} />
          <input
            :if={@registration_handoff}
            type="hidden"
            name="registration_handoff"
            value={@registration_handoff}
          />
          <.button
            id="resend-code"
            type="submit"
            variant={:secondary}
            class="w-full"
            phx-hook="ResendCooldown"
            data-seconds="30"
            data-label="Resend code"
          >
            Resend code
          </.button>
        </.form>

        <.simple_form
          :if={@registered? && @email}
          for={@email_form}
          action={~p"/sign_up/email"}
          method="post"
          class="mt-5"
        >
          <.input
            name="user[email]"
            value={@correction_email || ""}
            type="email"
            label="Wrong address?"
            autocomplete="email"
            errors={List.wrap(@correction_email_error)}
            required
          />
          <:actions>
            <.button type="submit" variant={:secondary} class="w-full">
              Send code to this email <span aria-hidden="true">→</span>
            </.button>
          </:actions>
        </.simple_form>

        <.auth_footer_link :if={!@registered?} navigate={~p"/sign_in/magic"}>
          <:lead>Wrong address?</:lead>
          Use a different email
        </.auth_footer_link>
      <% else %>
        <p class="mb-6 text-sm text-zinc-400">
          We'll email you a one-time <span class="whitespace-nowrap">sign-in link</span>
          and a <span class="whitespace-nowrap">6-character code</span>. They expire in 15 minutes.
        </p>

        <.simple_form for={@email_form} action={~p"/sign_in/magic/start"} method="post">
          <input type="hidden" name="return_to" value={@return_to} />
          <.input
            field={@email_form[:email]}
            type="email"
            label="Work email"
            autocomplete="email"
            required
          />
          <:actions>
            <.button class="w-full">
              Email me a sign-in link <span aria-hidden="true">→</span>
            </.button>
          </:actions>
        </.simple_form>

        <%!-- Never a dead end: a cold/expired-link visit gets the same
             exits the sign-in page offers. --%>
        <.auth_footer_link navigate={~p"/sign_in"}>
          <:lead>Prefer SSO?</:lead>
          Back to sign in
        </.auth_footer_link>
        <.auth_footer_link navigate={~p"/sign_up"}>
          <:lead>New to emisar?</:lead>
          Create an account
        </.auth_footer_link>
      <% end %>
    </.auth_layout>
    """
  end
end
