defmodule EmisarWeb.MagicLinkLive do
  use EmisarWeb, :live_view
  alias Emisar.{Auth, Throttle}
  alias EmisarWeb.{MagicLinkHandoff, MfaErrors, RequestContext}

  # The "check your email" page for every emailed code — a workspace sign-in, an
  # invitation, a sign-up. The request was started by a controller (issuing the
  # code sets a signed nonce cookie a LiveView can't), which stashed the request
  # in the session. The typed code is verified HERE (handle_event/3) so a wrong
  # code shows inline with no reload; on a match we redirect to
  # `:magic_link_complete` with a short-lived, cookie-bound handoff that
  # establishes the session. Without a pending request there is nothing to
  # verify, so the page goes to `/sign_in`.
  def mount(_params, session, socket) do
    case pending_request(session) do
      {:ok, token_id, nonce} ->
        {:ok,
         socket
         |> assign(:page_title, "Check your email")
         # The address the start stashed, shown so the operator recognizes it;
         # empty for an over-long input.
         |> assign(:email, session["magic_link_email"])
         # The code's expiry (ISO8601) — the page counts it down and disables
         # the code form when it lapses.
         |> assign(:expires_at, session["magic_link_expires_at"])
         # Where the request began: the workspace sign-in, the invitation, or
         # sign-up — a path the server built.
         |> assign(:back_to, back_to(session))
         # Phoenix passes mount the verified cookie session server-side, while
         # the router's auth_live_session controls the smaller map signed into
         # data-phx-session. Those exported keys deliberately omit both halves.
         |> assign(:token_id, token_id)
         |> assign(:nonce, nonce)
         |> assign(:request_context, RequestContext.from_socket(socket))
         |> assign(:code_error, nil)
         # The boxes are client-owned (`phx-update="ignore"`), so the reject path
         # clears them by pushing to this element rather than re-rendering it.
         |> assign(:code_input_id, "magic-code")
         |> assign(:code_form, to_form(%{"code" => ""}))}

      :error ->
        {:ok, redirect(socket, to: ~p"/sign_in")}
    end
  end

  # The typed code, aggregated by the CodeInput hook into the hidden `code` field.
  # A wrong/expired code stays on the page with an inline error at the boxes —
  # never a redirect to a far-off flash. A verified code hands off to the
  # controller to set the session cookie (a LiveView can't set it).
  def handle_event("verify_code", %{"code" => code}, socket) do
    %{token_id: token_id, nonce: nonce, request_context: context} = socket.assigns
    code = code |> to_string() |> String.trim() |> String.upcase()

    with :ok <- Throttle.check("magic_link_verify", context.ip_address, 30, 60_000),
         {:ok, membership_id} <- Auth.verify_magic_link(token_id, code, nonce, context) do
      handoff = MagicLinkHandoff.sign(membership_id, token_id)
      {:noreply, redirect(socket, to: ~p"/sign_in/magic/complete?#{[handoff: handoff]}")}
    else
      # The cap is per IP, so one NAT egress trips it for a whole team at once.
      # Told "that code didn't match", every one of them retypes a code that was
      # never wrong and then spends the separate resend budget burning it.
      {:error, :rate_limited} ->
        {:noreply, reject_code(socket, MfaErrors.message(:rate_limited))}

      _ ->
        {:noreply,
         reject_code(
           socket,
           "That code didn't match or has expired. Check it and try again, or resend below."
         )}
    end
  end

  # Empty the boxes and refocus: a rejected code left in place meant fixing
  # one character refilled all six, which auto-submits and spends another of
  # the five attempts on a code the operator was still correcting.
  defp reject_code(socket, message) do
    socket
    |> assign(:code_error, message)
    |> push_event("code:reset", %{id: socket.assigns.code_input_id})
  end

  defp pending_request(session) do
    case {session["magic_link_token_id"], session["magic_link_nonce"]} do
      {token_id, nonce} when is_binary(token_id) and is_binary(nonce) -> {:ok, token_id, nonce}
      _ -> :error
    end
  end

  defp back_to(session) do
    case session["magic_link_back_to"] do
      "/" <> _ = path -> path
      _ -> ~p"/sign_in"
    end
  end

  def render(assigns) do
    ~H"""
    <.auth_layout title="Check your email">
      <.callout tone={:brand} icon="state.magic_link_sent" title="Check your inbox">
        <p :if={@email not in [nil, ""]} class="mt-1.5">
          We emailed a sign-in link and a 6-character code to <code class="font-mono text-brand-100">{@email}</code>. Enter
          the code here, or open the link from <em>this same browser</em>. Both expire in
          15 minutes.
        </p>
        <p :if={@email in [nil, ""]} class="mt-1.5">
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
          data-disable-inputs={@code_input_id}
          class="mt-3 text-xs font-medium text-brand-300/80"
        >
        </p>
      </.callout>

      <.simple_form for={@code_form} phx-submit="verify_code" class="mt-5">
        <.code_input
          id={@code_input_id}
          name="code"
          label="Sign-in code"
          error={@code_error}
        />
        <:actions>
          <.button id="code-submit" class="w-full">
            Sign in <span aria-hidden="true">→</span>
          </.button>
        </:actions>
      </.simple_form>

      <%!-- Resend: a secondary button the ResendCooldown hook disables for a
            short countdown ("Resend in 0:29") so an operator can't hammer the
            send, then re-enables. The server's address budget (5 / 15 min) is
            the real limit and surfaces a clear flash when hit. The request the
            browser holds says what to resend; the form carries nothing. --%>
      <.form for={%{}} action={~p"/sign_in/magic/resend"} method="post" class="mt-3">
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

      <.auth_footer_link href={@back_to}>
        <:lead>Wrong address?</:lead>
        Start again
      </.auth_footer_link>
    </.auth_layout>
    """
  end
end
