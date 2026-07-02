defmodule EmisarWeb.MfaChallengeLive do
  use EmisarWeb, :live_view
  alias Emisar.{Auth, Users}
  alias EmisarWeb.{MfaChallengeHandoff, RequestContext, Throttle}

  # The second factor, after a magic link has verified email possession. The
  # partial-auth session (`:mfa_pending_user_id`) names the user but grants no
  # access — a full session is minted only once TOTP or a recovery code verifies
  # HERE. The code is checked in handle_event (inline error, no reload); on a
  # match we redirect to `:mfa_complete` with a signed handoff the controller
  # trades — together with the still-matching pending session — for the session
  # cookie a LiveView can't set. A brute-force cap lives in `Throttle` (server-
  # side, so it survives a page reload), on top of TOTP replay protection.
  @attempt_limit 5
  @attempt_window_ms 5 * 60_000

  def mount(_params, session, socket) do
    case pending_user(session) do
      {:ok, user} ->
        {:ok,
         socket
         |> assign(:page_title, "Two-factor authentication")
         |> assign(:user, user)
         |> assign(:mode, :totp)
         |> assign(:error, nil)
         |> assign(:request_context, RequestContext.from_socket(socket))
         |> assign(:recovery_form, to_form(%{"code" => ""}))}

      :error ->
        # No pending challenge (opened directly, or the marker was consumed /
        # expired) — nothing to verify, so send them to start a sign-in.
        {:ok, redirect(socket, to: ~p"/sign_in/magic")}
    end
  end

  def handle_event("verify_totp", %{"otp" => otp}, socket) do
    verify(socket, &Auth.verify_mfa(&1, otp, socket.assigns.request_context))
  end

  def handle_event("verify_recovery", %{"code" => code}, socket) do
    verify(socket, &Auth.consume_mfa_recovery_code(&1, code, socket.assigns.request_context))
  end

  # The mode toggle clears the error so a stale "didn't match" doesn't linger on
  # the other input.
  def handle_event("use_recovery", _params, socket),
    do: {:noreply, socket |> assign(:mode, :recovery) |> assign(:error, nil)}

  def handle_event("use_totp", _params, socket),
    do: {:noreply, socket |> assign(:mode, :totp) |> assign(:error, nil)}

  # One verification path for both factors: the brute-force cap first (keyed by
  # user, so a reload can't reset it), then the caller's verify fn. A pass hands
  # off to the controller; a failure (or a rate-limit) stays put with an inline
  # error — `verify_mfa`/`consume_mfa_recovery_code` already audit the miss.
  defp verify(socket, verify_fun) do
    user = socket.assigns.user

    with :ok <- Throttle.check(:mfa_challenge, user.id, @attempt_limit, @attempt_window_ms),
         :ok <- verify_fun.(user) do
      handoff = MfaChallengeHandoff.sign(user.id)
      {:noreply, redirect(socket, to: ~p"/sign_in/mfa/complete?#{[handoff: handoff]}")}
    else
      {:error, :rate_limited} ->
        {:noreply, assign(socket, :error, "Too many attempts. Wait a minute, then try again.")}

      {:error, _} ->
        {:noreply, assign(socket, :error, error_message(socket.assigns.mode))}
    end
  end

  defp error_message(:totp),
    do: "That code didn't match. Check your authenticator app and try again."

  defp error_message(:recovery),
    do: "That recovery code didn't match or has already been used."

  defp pending_user(session) do
    with id when is_binary(id) <- session["mfa_pending_user_id"],
         {:ok, %Users.User{mfa_enabled_at: %DateTime{}} = user} <- Users.fetch_user_by_id(id) do
      {:ok, user}
    else
      _ -> :error
    end
  end

  def render(assigns) do
    ~H"""
    <.auth_layout title="Two-factor authentication">
      <%= if @mode == :totp do %>
        <p class="mb-6 text-sm text-zinc-400">
          Enter the 6-digit code from your authenticator app to finish signing in.
        </p>

        <.simple_form for={%{}} phx-submit="verify_totp">
          <.code_input id="mfa-otp" name="otp" numeric label="Authenticator code" error={@error} />
          <:actions>
            <.button class="w-full">
              Verify <span aria-hidden="true">→</span>
            </.button>
          </:actions>
        </.simple_form>

        <.mode_switch event="use_recovery" lead="Lost your device?">
          Use a recovery code
        </.mode_switch>
      <% else %>
        <p class="mb-6 text-sm text-zinc-400">
          Enter one of the <span class="whitespace-nowrap">recovery codes</span>
          you saved when you set up two-factor authentication. Each code works once.
        </p>

        <.simple_form for={@recovery_form} phx-submit="verify_recovery">
          <.input
            field={@recovery_form[:code]}
            type="text"
            label="Recovery code"
            autocomplete="one-time-code"
            required
          />
          <%!-- Rendered directly (not via <.input>'s feedback-gated path) so an
               assigned error shows on submit, matching code_input's inline error. --%>
          <.error :if={@error}>{@error}</.error>
          <:actions>
            <.button class="w-full">
              Verify <span aria-hidden="true">→</span>
            </.button>
          </:actions>
        </.simple_form>

        <.mode_switch event="use_totp" lead="Have your authenticator?">
          Enter a code instead
        </.mode_switch>
      <% end %>

      <.auth_footer_link navigate={~p"/sign_in/magic"}>
        <:lead>Not you?</:lead>
        Start over
      </.auth_footer_link>
    </.auth_layout>
    """
  end

  # The factor toggle — the `auth_footer_link` switch-line shape, but firing a
  # phx-click action rather than navigating. (auth_footer_link takes only
  # navigate/href; giving it an action slot to converge these is a BACKLOG item —
  # core_components is mid-flight in a parallel session and can't be touched here.)
  attr :event, :string, required: true
  attr :lead, :string, required: true
  slot :inner_block, required: true

  defp mode_switch(assigns) do
    ~H"""
    <p class="mt-6 text-center text-sm text-zinc-400">
      {@lead}
      <button
        type="button"
        phx-click={@event}
        class="font-medium text-brand-400 hover:text-brand-300"
      >
        {render_slot(@inner_block)}
      </button>
    </p>
    """
  end
end
