defmodule EmisarWeb.ProfileLive do
  @moduledoc """
  The Member's own page in this workspace: Profile (the name shown here; the
  email it was invited or signed up with, read-only), Multi-factor
  authentication (this Member's factor, enrolled with a fresh proof of its own
  credential), and Active sessions (this Member's sessions in this workspace).

  Everything here belongs to one Member in one workspace — there is no
  personal login behind it, so nothing on this page reaches another workspace.
  """
  use EmisarWeb, :live_view
  alias Emisar.{Accounts, ApiKeys, Auth}
  alias EmisarWeb.{LiveForm, LiveTable, MfaEnrollment, MfaErrors, UserAgent, UserAuth}
  alias Phoenix.LiveView.JS

  @mfa_enrollment_email_unavailable_error "Your email address isn't verified, so we can't send a code to it. Ask your workspace administrator for help, or contact support@emisar.dev."
  @mfa_enrollment_email_suppressed_error "Emisar cannot deliver mail to your address. Contact support to restore email delivery before setting up MFA."
  @mfa_enrollment_email_delivery_error "We could not deliver the verification code. Try again. If it keeps failing, contact support."

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Profile")
     |> assign(:profile_editing?, false)
     |> assign(:profile_editable?, false)
     |> assign(:profile_error?, false)
     |> assign(:profile_loaded?, false)
     |> assign_profile_form(socket.assigns.current_membership)
     |> assign(:email_changeable?, false)
     |> reset_email_step()
     |> assign_email_form(socket.assigns.current_membership)
     |> assign(:mfa_facts, nil)
     |> assign(:mfa_recovery_codes, nil)
     |> assign(:codes_saved?, false)
     |> assign(:mfa_start_error, nil)
     |> assign(:mfa_recovery_regeneration_step, :idle)
     |> assign(:mfa_recovery_regeneration_error, nil)
     |> assign(:mfa_disable_step, :idle)
     |> assign(:mfa_disable_error, nil)
     |> MfaEnrollment.reset()
     |> assign_mfa_enrollment_email_form()
     |> assign_mfa_form()
     |> assign_mfa_recovery_regeneration_form()
     |> assign_mfa_disable_form()
     |> assign(:session_count, 0)
     |> assign(:session_page_count, 0)
     |> assign(:metadata, %Emisar.Repo.Paginator.Metadata{count: 0, limit: 0})
     |> assign(:filter_params, %{})
     |> assign(:sessions_error?, false)
     |> assign(:sessions_loaded?, false)
     |> stream(:sessions, [])}
  end

  def handle_params(params, _uri, socket), do: {:noreply, maybe_load(socket, params)}

  # IL-18: load after connecting; static HTML shows loading, not an empty
  # result. Session pagination preserves its URL state.
  # A session that stopped authenticating redirects once from the first read;
  # the other reads are skipped rather than redirect again.
  defp maybe_load(socket, params) do
    if connected?(socket) do
      socket = load_sessions(socket, params)
      if socket.redirected, do: socket, else: socket |> load_profile() |> assign_mfa_facts()
    else
      assign(socket, :filter_params, params)
    end
  end

  defp load_profile(socket) do
    socket = assign(socket, :profile_loaded?, true)

    case Accounts.fetch_own_member_profile(socket.assigns.current_subject) do
      {:ok, %{membership: member, editable?: editable?, email_changeable?: email_changeable?}} ->
        socket =
          socket
          |> assign(:current_membership, member)
          |> assign(:profile_editable?, editable?)
          |> assign(:email_changeable?, email_changeable?)
          |> assign(:profile_error?, false)

        if socket.assigns.profile_editing?,
          do: socket,
          else: assign_profile_form(socket, member)

      {:error, _} ->
        socket
        |> assign(:profile_editable?, false)
        |> assign(:profile_error?, true)
    end
  end

  # Email-change state: :idle (the current address), :edit (the new one), :mfa
  # (an authenticator code) or :email (a code sent to the current address), then
  # :new_address (the new inbox's code). The split nonce stays in this LiveView,
  # never in an email.
  defp reset_email_step(socket) do
    socket
    |> assign(:email_step, :idle)
    |> assign(:pending_new_email, nil)
    |> assign(:new_email_proof, nil)
    |> assign(:email_step_error, nil)
    |> assign(:email_step_form, to_form(%{"code" => ""}, as: "email_step"))
  end

  defp assign_email_form(socket, member),
    do: assign(socket, :email_form, to_form(Accounts.change_member_email(member), as: "email"))

  defp start_email_step_up(socket, new_email) do
    socket =
      socket
      |> assign(:new_email_proof, nil)
      |> assign(:email_step_error, nil)

    case Auth.begin_email_change(new_email, socket.assigns.current_subject) do
      {:ok, :mfa} ->
        socket
        |> assign(:pending_new_email, new_email)
        |> assign(:email_step, :mfa)

      {:ok, :email} ->
        socket
        |> assign(:pending_new_email, new_email)
        |> assign(:email_step, :email)
        |> put_flash(:info, "We emailed a code to #{socket.assigns.current_membership.email}.")

      {:error, %Ecto.Changeset{} = changeset} ->
        assign(socket, :email_form, to_form(changeset, as: "email"))

      {:error, :delivery_suppressed} ->
        assign(socket, :email_step_error, current_address_suppressed(socket))

      {:error, :rate_limited} ->
        assign(socket, :email_step_error, MfaErrors.message(:email_rate_limited))

      {:error, :email_change_unavailable} ->
        socket
        |> reset_email_step()
        |> put_flash(:error, "You can't change this email here.")

      {:error, :unauthorized} ->
        UserAuth.reauthenticate(socket)

      {:error, _reason} ->
        assign(socket, :email_step_error, "Couldn't start the email change. Try again.")
    end
  end

  defp confirm_email_step(socket, code) do
    step = socket.assigns.email_step
    socket = push_event(socket, "code:reset", %{id: email_code_input_id(step)})
    subject = socket.assigns.current_subject

    result =
      case step do
        :new_address ->
          proof = socket.assigns.new_email_proof
          Auth.complete_email_change(proof.token_id, proof.nonce, code, subject)

        _factor ->
          Auth.confirm_email_change(socket.assigns.pending_new_email, code, subject)
      end

    case result do
      {:ok, %Accounts.Membership{} = updated} ->
        socket
        |> assign(:current_membership, updated)
        |> reset_email_step()
        |> assign_email_form(updated)
        |> put_flash(:info, "Your email is now #{updated.email}.")

      {:ok, %{token_id: _id, nonce: _nonce, email: email} = proof} ->
        socket
        |> assign(:email_step, :new_address)
        |> assign(:new_email_proof, proof)
        |> assign(:email_step_error, nil)
        |> put_flash(:info, "We sent a code to #{email}. Your email hasn't changed yet.")

      {:error, error} when error in [:invalid, :invalid_code] ->
        assign(socket, :email_step_error, step_up_error(step))

      {:error, :replay} ->
        assign(socket, :email_step_error, "That code was just used. Wait for the next one.")

      {:error, :rate_limited} ->
        assign(socket, :email_step_error, MfaErrors.message(:rate_limited))

      {:error, :unauthorized} ->
        UserAuth.reauthenticate(socket)

      {:error, :email_change_unavailable} ->
        socket
        |> reset_email_step()
        |> put_flash(:error, "You can't change this email here.")

      # The step-up was spent: an address another member took meanwhile, or one
      # that can't receive mail, goes back to the start.
      {:error, %Ecto.Changeset{} = changeset} ->
        socket
        |> reset_email_step()
        |> assign(:email_step, :edit)
        |> assign(:email_form, to_form(changeset, as: "email"))

      {:error, :delivery_suppressed} ->
        socket
        |> reset_email_step()
        |> assign(:email_step, :edit)
        |> assign(
          :email_step_error,
          "We can't deliver to that address. Check it and try again. Your email hasn't changed."
        )

      {:error, :email_change_stale} ->
        socket
        |> reset_email_step()
        |> assign(:email_step, :edit)
        |> assign(:email_step_error, "Your account changed. Start the email change again.")

      {:error, _reason} ->
        socket
        |> reset_email_step()
        |> assign(:email_step, :edit)
        |> assign(:email_step_error, "Couldn't change your email. Try again.")
    end
  end

  defp step_up_error(:mfa), do: MfaErrors.message(:step_up_factor_invalid)
  defp step_up_error(_step), do: MfaErrors.message(:email_code_invalid)

  defp current_address_suppressed(socket) do
    "We can't send a code to your current email (#{socket.assigns.current_membership.email}). " <>
      "Contact support@emisar.dev."
  end

  # A code input owns an ignored DOM subtree and keeps its numeric mode from
  # mount, so each step gets its own id: the new-address code admits letters.
  defp email_code_input_id(step), do: "email-step-code-#{step}"

  defp assign_profile_form(socket, member, attrs \\ %{}) do
    assign(
      socket,
      :profile_form,
      to_form(Accounts.change_member_profile(member, attrs), as: "profile")
    )
  end

  # 10 a page: a heavy automation account can hold ~100 sessions, and an
  # ungrouped wall of near-identical rows buries the one unfamiliar device an
  # operator is scanning for. Cursor-paginated (UserToken.Query.cursor_fields).
  defp load_sessions(socket, params) do
    socket = assign(socket, :sessions_loaded?, true)
    opts = LiveTable.params_to_opts(params)
    list_opts = Keyword.put(opts, :page, Keyword.put(opts[:page], :limit, 10))

    presented_digest = socket.assigns.current_auth.token

    case Auth.list_sessions_for_member(
           presented_digest,
           socket.assigns.current_subject,
           list_opts
         ) do
      {:ok, sessions, metadata} ->
        presented = Enum.map(sessions, &present_session/1)

        socket
        |> assign(:session_count, metadata.count || 0)
        |> assign(:session_page_count, length(presented))
        |> assign(:metadata, metadata)
        |> assign(:filter_params, params)
        |> assign(:sessions_error?, false)
        |> stream(:sessions, presented, reset: true)

      # The session reading this page no longer authenticates: a sign-in step.
      {:error, :unauthorized} ->
        UserAuth.reauthenticate(socket)

      # A bad cursor from a hand-edited URL — retry once, clean, on page 1.
      {:error, _} when map_size(params) > 0 ->
        load_sessions(socket, %{})

      # You are reading this page from a live session, so an empty device list
      # can only be a failed read — and this is the list an operator scans for a
      # device they don't recognize.
      {:error, _} ->
        socket
        |> assign(:session_count, 0)
        |> assign(:session_page_count, 0)
        |> assign(:metadata, %Emisar.Repo.Paginator.Metadata{count: 0, limit: 0})
        |> assign(:filter_params, params)
        |> assign(:sessions_error?, true)
        |> stream(:sessions, [], reset: true)
    end
  end

  # Reload the page the operator is on after a revoke, so a single sign-out
  # doesn't bounce them back to page 1 (their cursor rides on filter_params).
  defp reload_sessions(socket), do: load_sessions(socket, socket.assigns.filter_params)

  defp present_session(%Auth.SessionFacts{} = session) do
    %{
      id: session.id,
      device_label: UserAgent.label(session.user_agent, version: true),
      icon: UserAgent.icon(session.user_agent),
      current?: session.current?,
      ip_address: session_ip(session.ip_address),
      inserted_at: session.inserted_at,
      sign_in_method: session_sign_in_method(session.auth_method)
    }
  end

  defp session_sign_in_method(:magic_link), do: "Email code"
  defp session_sign_in_method(:sso), do: "Single sign-on"
  defp session_sign_in_method(nil), do: nil

  # -- Profile ---------------------------------------------------------

  def handle_event("edit_profile", _params, socket) do
    socket = load_profile(socket)

    cond do
      socket.assigns.profile_error? ->
        {:noreply, socket}

      socket.assigns.profile_editable? ->
        {:noreply, socket |> reset_email_step() |> assign(:profile_editing?, true)}

      true ->
        {:noreply, put_flash(socket, :error, "Your name is managed by your identity provider.")}
    end
  end

  def handle_event("cancel_profile", _params, socket) do
    {:noreply,
     socket
     |> assign(:profile_editing?, false)
     |> assign_profile_form(socket.assigns.current_membership)}
  end

  def handle_event("validate_profile", %{"profile" => attrs} = event, socket) do
    changeset =
      socket.assigns.current_membership
      |> Accounts.change_member_profile(attrs)
      |> LiveForm.on_change(event)

    {:noreply, assign(socket, :profile_form, to_form(changeset, as: "profile"))}
  end

  def handle_event("save_profile", %{"profile" => attrs}, socket) do
    case Accounts.update_own_member_profile(attrs, socket.assigns.current_subject) do
      {:ok, member} ->
        {:noreply,
         socket
         |> assign(:current_membership, member)
         |> assign(:profile_editing?, false)
         |> assign_profile_form(member)
         |> put_flash(:info, "Name updated.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :profile_form, to_form(changeset, as: "profile"))}

      {:error, :unauthorized} ->
        {:noreply, UserAuth.reauthenticate(socket)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign_profile_form(socket.assigns.current_membership, attrs)
         |> put_flash(:error, EmisarWeb.MemberErrors.message(reason))}
    end
  end

  # -- Active sessions -------------------------------------------------

  def handle_event("edit_email", _params, socket) do
    {:noreply,
     socket
     |> reset_email_step()
     |> assign(:email_step, :edit)
     |> assign_email_form(socket.assigns.current_membership)}
  end

  def handle_event("validate_email", %{"email" => params} = event, socket) do
    changeset =
      socket.assigns.current_membership
      |> Accounts.change_member_email(String.trim(params["email"] || ""))
      |> LiveForm.on_change(event)

    {:noreply,
     socket
     |> assign(:email_form, to_form(changeset, as: "email"))
     |> assign(:email_step_error, nil)}
  end

  # The email decides where every future sign-in code goes, so changing it is
  # gated like a credential: submitting only STARTS a step-up (the Member's
  # authenticator, or a code to its current address), and only then can this
  # browser prove the new inbox. The domain picks the factor from the fresh row.
  def handle_event("save_email", %{"email" => params}, socket) do
    if socket.assigns.email_step == :edit do
      {:noreply, start_email_step_up(socket, String.trim(params["email"] || ""))}
    else
      {:noreply, put_flash(socket, :error, "Start an email change first.")}
    end
  end

  def handle_event("confirm_email_change", %{"email_step" => %{"code" => code}}, socket) do
    if socket.assigns.email_step in [:mfa, :email, :new_address] do
      {:noreply, confirm_email_step(socket, String.trim(code || ""))}
    else
      {:noreply, put_flash(socket, :error, "Start an email change first.")}
    end
  end

  def handle_event("resend_email_code", _params, socket) do
    if socket.assigns.email_step == :email do
      case Auth.resend_email_change_code(
             socket.assigns.pending_new_email,
             socket.assigns.current_subject
           ) do
        {:ok, :sent} ->
          {:noreply,
           socket
           |> assign(:email_step_error, nil)
           |> push_event("code:reset", %{id: email_code_input_id(:email)})
           |> put_flash(
             :info,
             "We sent a new code to #{socket.assigns.current_membership.email}."
           )}

        {:ok, :suppressed} ->
          {:noreply, assign(socket, :email_step_error, current_address_suppressed(socket))}

        {:error, :factor_changed} ->
          {:noreply,
           socket
           |> assign(:email_step, :mfa)
           |> assign(:email_step_error, nil)
           |> put_flash(:info, "Use your authenticator app instead.")}

        {:error, :rate_limited} ->
          {:noreply, assign(socket, :email_step_error, MfaErrors.message(:email_rate_limited))}

        {:error, :unauthorized} ->
          {:noreply, UserAuth.reauthenticate(socket)}

        {:error, _reason} ->
          {:noreply, assign(socket, :email_step_error, "Couldn't send a new code. Try again.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Start an email change first.")}
    end
  end

  def handle_event("cancel_email_change", _params, socket) do
    {:noreply,
     socket
     |> reset_email_step()
     |> assign_email_form(socket.assigns.current_membership)}
  end

  def handle_event("retry_sessions", _params, socket),
    do: {:noreply, reload_sessions(socket)}

  def handle_event("revoke_session", %{"id" => id}, socket) do
    case Auth.revoke_session(id, socket.assigns.current_subject) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Session signed out.") |> reload_sessions()}

      {:error, :not_found} ->
        {:noreply,
         socket |> put_flash(:info, "This session has already ended.") |> reload_sessions()}

      {:error, :unauthorized} ->
        {:noreply, UserAuth.reauthenticate(socket)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't sign out this session. Try again.")}
    end
  end

  def handle_event("revoke_other_sessions", _params, socket) do
    keep_digest = socket.assigns.current_auth.token

    case Auth.revoke_and_disconnect_other_sessions(keep_digest, socket.assigns.current_subject) do
      {:ok, count} ->
        msg =
          if count == 0, do: "No other sessions to sign out.", else: "Other sessions signed out."

        # The surviving current session is on page 1, not the old paging cursor.
        {:noreply, socket |> put_flash(:info, msg) |> load_sessions(%{})}

      {:error, :unauthorized} ->
        {:noreply, UserAuth.reauthenticate(socket)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't sign out other sessions. Try again.")}
    end
  end

  # -- Multi-factor authentication -------------------------------------

  # The inbox-code enrollment path. An SSO-only Member takes the "Verify with
  # <provider>" form instead, which posts to the MFA setup page's SSO
  # ceremony and finishes enrollment there.
  def handle_event("start_mfa", _params, socket) do
    case Auth.issue_mfa_enrollment_code(socket.assigns.current_subject) do
      {:ok, :sent} ->
        {:noreply,
         socket
         |> assign(:mfa_enrollment_step, :email)
         |> assign(:mfa_start_error, nil)
         |> assign(:mfa_enrollment_email_error, nil)
         |> put_flash(:info, "We emailed a verification code to your address.")}

      {:ok, :suppressed} ->
        {:noreply, assign(socket, :mfa_start_error, @mfa_enrollment_email_suppressed_error)}

      {:error, :rate_limited} ->
        {:noreply, assign(socket, :mfa_start_error, MfaErrors.message(:email_rate_limited))}

      {:error, :email_unavailable} ->
        {:noreply, assign(socket, :mfa_start_error, @mfa_enrollment_email_unavailable_error)}

      {:error, :mfa_already_enabled} ->
        {:noreply, refresh_after_mfa_enabled(socket)}

      {:error, :unauthorized} ->
        {:noreply, UserAuth.reauthenticate(socket)}

      {:error, _reason} ->
        {:noreply, assign(socket, :mfa_start_error, @mfa_enrollment_email_delivery_error)}
    end
  end

  def handle_event(
        "verify_mfa_enrollment_email",
        %{"mfa_enrollment" => %{"code" => code}},
        socket
      ) do
    if socket.assigns.mfa_enrollment_step == :email do
      socket = push_event(socket, "code:reset", %{id: "mfa-enrollment-email-code"})

      case Auth.verify_mfa_enrollment_code(
             String.trim(code || ""),
             socket.assigns.current_subject
           ) do
        {:ok, proof} ->
          {:noreply, socket |> MfaEnrollment.prepare_authenticator(proof) |> assign_mfa_form()}

        {:error, :invalid} ->
          {:noreply,
           assign(socket, :mfa_enrollment_email_error, MfaErrors.message(:email_code_invalid))}

        {:error, :rate_limited} ->
          {:noreply,
           assign(socket, :mfa_enrollment_email_error, MfaErrors.message(:rate_limited))}

        {:error, :email_unavailable} ->
          {:noreply,
           socket
           |> put_flash(:error, @mfa_enrollment_email_unavailable_error)
           |> MfaEnrollment.reset()
           |> assign_mfa_enrollment_email_form()
           |> assign_mfa_form()}

        {:error, :mfa_already_enabled} ->
          {:noreply, refresh_after_mfa_enabled(socket)}

        {:error, :unauthorized} ->
          {:noreply, UserAuth.reauthenticate(socket)}

        {:error, _reason} ->
          {:noreply,
           assign(socket, :mfa_enrollment_email_error, "Could not verify that code. Try again.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Start MFA setup again.")}
    end
  end

  def handle_event("resend_mfa_enrollment_email", _params, socket) do
    if socket.assigns.mfa_enrollment_step == :email do
      case Auth.issue_mfa_enrollment_code(socket.assigns.current_subject) do
        {:ok, :sent} ->
          {:noreply,
           socket
           |> assign(:mfa_enrollment_email_error, nil)
           |> push_event("code:reset", %{id: "mfa-enrollment-email-code"})
           |> put_flash(:info, "We sent a new verification code.")}

        {:ok, :suppressed} ->
          {:noreply,
           assign(socket, :mfa_enrollment_email_error, @mfa_enrollment_email_suppressed_error)}

        {:error, :rate_limited} ->
          {:noreply,
           assign(socket, :mfa_enrollment_email_error, MfaErrors.message(:email_rate_limited))}

        {:error, :mfa_already_enabled} ->
          {:noreply, refresh_after_mfa_enabled(socket)}

        {:error, :unauthorized} ->
          {:noreply, UserAuth.reauthenticate(socket)}

        {:error, _reason} ->
          {:noreply,
           assign(socket, :mfa_enrollment_email_error, @mfa_enrollment_email_delivery_error)}
      end
    else
      {:noreply, put_flash(socket, :error, "Start MFA setup again.")}
    end
  end

  def handle_event("cancel_mfa", _params, socket) do
    {:noreply,
     socket |> MfaEnrollment.reset() |> assign_mfa_enrollment_email_form() |> assign_mfa_form()}
  end

  def handle_event("confirm_mfa", %{"mfa" => %{"otp" => otp}}, socket) do
    secret = socket.assigns.mfa_secret

    if is_nil(secret) do
      {:noreply, put_flash(socket, :error, "Start MFA setup again.")}
    else
      case Auth.enable_mfa(
             secret,
             otp,
             socket.assigns.mfa_enrollment_proof,
             socket.assigns.current_auth.token,
             socket.assigns.current_subject
           ) do
        {:ok, updated, recovery_codes} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             "MFA enabled. Copy your recovery codes below. They'll only be shown once."
           )
           |> MfaEnrollment.assign_current_proof(updated)
           |> assign_mfa_facts()
           |> assign(:mfa_recovery_codes, recovery_codes)
           |> assign(:codes_saved?, false)
           |> MfaEnrollment.reset()
           |> assign(:mfa_enrollment_step, :recovery)
           |> assign_mfa_enrollment_email_form()
           |> assign_mfa_form()}

        {:error, :invalid_otp} ->
          {:noreply,
           socket
           |> assign(:mfa_error, MfaErrors.message(:invalid_otp))
           |> push_event("code:reset", %{id: "mfa-otp"})}

        {:error, :mfa_enrollment_proof_stale} ->
          {:noreply,
           socket
           |> put_flash(:error, MfaErrors.message(:mfa_enrollment_proof_stale))
           |> MfaEnrollment.reset()
           |> assign_mfa_enrollment_email_form()
           |> assign_mfa_form()}

        {:error, reason} when reason in [:unauthorized, :session_not_found] ->
          {:noreply, UserAuth.reauthenticate(socket)}

        {:error, :mfa_already_enabled} ->
          {:noreply, refresh_after_mfa_enabled(socket)}

        {:error, _changeset} ->
          {:noreply, assign(socket, :mfa_error, MfaErrors.message(:enable_failed))}
      end
    end
  end

  def handle_event("start_regenerate_recovery_codes", _params, socket) do
    {:noreply,
     socket
     |> assign(:mfa_recovery_regeneration_step, :code)
     |> assign(:mfa_recovery_regeneration_error, nil)
     |> assign(:mfa_disable_step, :idle)
     |> assign_mfa_recovery_regeneration_form()
     |> assign_mfa_disable_form()}
  end

  def handle_event("cancel_regenerate_recovery_codes", _params, socket) do
    {:noreply, reset_mfa_recovery_regeneration(socket)}
  end

  def handle_event(
        "regenerate_recovery_codes",
        %{"mfa_recovery_regeneration" => %{"code" => code}},
        socket
      ) do
    submit_recovery_code_regeneration(socket, code)
  end

  def handle_event("regenerate_recovery_codes", _params, socket) do
    submit_recovery_code_regeneration(socket, nil)
  end

  def handle_event("dismiss_recovery_codes", _params, socket) do
    if socket.assigns.mfa_recovery_codes && socket.assigns.codes_saved? do
      {:noreply, socket |> assign(:mfa_recovery_codes, nil) |> MfaEnrollment.reset()}
    else
      {:noreply, put_flash(socket, :error, MfaErrors.message(:recovery_codes_unsaved))}
    end
  end

  def handle_event("toggle_codes_saved", _params, socket) do
    if socket.assigns.mfa_recovery_codes do
      {:noreply, update(socket, :codes_saved?, &(not &1))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("start_disable_mfa", _params, socket) do
    {:noreply,
     socket
     |> reset_mfa_recovery_regeneration()
     |> assign(:mfa_disable_step, :code)
     |> assign(:mfa_disable_error, nil)
     |> assign_mfa_disable_form()}
  end

  def handle_event("cancel_disable_mfa", _params, socket) do
    {:noreply,
     socket
     |> assign(:mfa_disable_step, :idle)
     |> assign(:mfa_disable_error, nil)
     |> assign_mfa_disable_form()}
  end

  def handle_event("disable_mfa", %{"mfa_disable" => %{"code" => code}}, socket) do
    submit_disable_mfa(socket, code)
  end

  def handle_event("disable_mfa", _params, socket) do
    submit_disable_mfa(socket, nil)
  end

  defp submit_disable_mfa(socket, code) do
    case Auth.disable_mfa(code, socket.assigns.current_subject) do
      {:error, :unauthorized} ->
        {:noreply, UserAuth.reauthenticate(socket)}

      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "MFA disabled.")
         |> assign(:current_membership, updated)
         |> assign_mfa_facts()
         |> assign(:mfa_recovery_codes, nil)
         |> assign(:mfa_disable_step, :idle)
         |> assign(:mfa_disable_error, nil)
         |> assign_mfa_disable_form()}

      {:error, :rate_limited} ->
        {:noreply,
         socket
         |> assign(:mfa_disable_step, :code)
         |> assign(:mfa_disable_error, MfaErrors.message(:rate_limited))}

      {:error, :invalid_code} ->
        {:noreply,
         socket
         |> assign(:mfa_disable_step, :code)
         |> assign(:mfa_disable_error, "That code did not match. Try again.")}

      {:error, :replay} ->
        {:noreply,
         socket
         |> assign(:mfa_disable_step, :code)
         |> assign(
           :mfa_disable_error,
           "That authenticator code was already used. Wait for the next code."
         )}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:mfa_disable_step, :code)
         |> assign(:mfa_disable_error, "Could not disable MFA. Try again.")}
    end
  end

  defp submit_recovery_code_regeneration(socket, code) do
    case Auth.regenerate_mfa_recovery_codes(code, socket.assigns.current_subject) do
      {:error, :unauthorized} ->
        {:noreply, UserAuth.reauthenticate(socket)}

      {:ok, updated, codes} ->
        {:noreply,
         socket
         |> put_flash(:info, "New recovery codes generated. Old codes are now invalid.")
         |> assign(:current_membership, updated)
         |> assign_mfa_facts()
         |> assign(:mfa_recovery_codes, codes)
         |> assign(:codes_saved?, false)
         |> reset_mfa_recovery_regeneration()}

      {:error, :rate_limited} ->
        {:noreply,
         socket
         |> assign(:mfa_recovery_regeneration_step, :code)
         |> assign(:mfa_recovery_regeneration_error, MfaErrors.message(:rate_limited))}

      {:error, :invalid_code} ->
        {:noreply,
         socket
         |> assign(:mfa_recovery_regeneration_step, :code)
         |> assign(:mfa_recovery_regeneration_error, "That code did not match. Try again.")}

      {:error, :replay} ->
        {:noreply,
         socket
         |> assign(:mfa_recovery_regeneration_step, :code)
         |> assign(
           :mfa_recovery_regeneration_error,
           "That authenticator code was already used. Wait for the next authenticator code."
         )}

      {:error, :mfa_not_enabled} ->
        {:noreply,
         socket
         |> put_flash(:error, "Enable MFA first.")
         |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/settings/profile")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:mfa_recovery_regeneration_step, :code)
         |> assign(
           :mfa_recovery_regeneration_error,
           "Could not generate recovery codes. Try again."
         )}
    end
  end

  # Facts come from the live session and the current Member row, never a held
  # snapshot. Expiry during a mounted page is a sign-in step, not a crash.
  defp assign_mfa_facts(socket) do
    case Auth.mfa_facts(socket.assigns.current_subject) do
      {:ok, facts} -> assign(socket, :mfa_facts, facts)
      {:error, :unauthorized} -> UserAuth.reauthenticate(socket)
    end
  end

  defp assign_mfa_form(socket) do
    assign(socket, :mfa_form, to_form(%{"otp" => ""}, as: "mfa"))
  end

  defp assign_mfa_enrollment_email_form(socket) do
    assign(socket, :mfa_enrollment_email_form, to_form(%{"code" => ""}, as: "mfa_enrollment"))
  end

  defp refresh_after_mfa_enabled(socket) do
    push_navigate(socket, to: ~p"/app/#{socket.assigns.current_account}/settings/profile")
  end

  defp assign_mfa_disable_form(socket) do
    assign(socket, :mfa_disable_form, to_form(%{"code" => ""}, as: "mfa_disable"))
  end

  defp assign_mfa_recovery_regeneration_form(socket) do
    assign(
      socket,
      :mfa_recovery_regeneration_form,
      to_form(%{"code" => ""}, as: "mfa_recovery_regeneration")
    )
  end

  defp reset_mfa_recovery_regeneration(socket) do
    socket
    |> assign(:mfa_recovery_regeneration_step, :idle)
    |> assign(:mfa_recovery_regeneration_error, nil)
    |> assign_mfa_recovery_regeneration_form()
  end

  defp session_ip(ip) when is_binary(ip) and ip != "", do: ip
  defp session_ip(_ip), do: nil

  # The identity provider behind this SSO session; `with_preloaded_authority/1`
  # carries it on the session row.
  defp sso_provider_name(%Auth.UserToken{user_identity: %{provider: %{name: name}}})
       when is_binary(name),
       do: name

  defp sso_provider_name(_auth), do: "your identity provider"

  # No-op for the broadcasts the on_mount badge/fleet hooks forward (approvals,
  # pack trust, runner presence). The hooks own those nav cues; this page ignores them.
  def handle_info(_msg, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <.console_shell
      chrome={@shell_chrome}
      current_membership={@current_membership}
      current_subject={@current_subject}
      current_account={@current_account}
      section={:profile}
      width={:table}
    >
      <:title>Profile</:title>

      <.page_intro>
        Your profile, multi-factor authentication and sessions in this workspace.
        <.doc_link href="/security">Security overview</.doc_link>
      </.page_intro>

      <div
        id="profile-layout"
        class="grid grid-cols-1 gap-x-12 gap-y-12 xl:grid-cols-[minmax(0,1fr)_18rem] xl:items-start"
      >
        <.section_with_note id="profile-details">
          <:header>
            <.section_header title="Profile">
              <:subtitle>
                How you appear in <span class="font-medium text-zinc-200">{@current_account.name}</span>.
              </:subtitle>
            </.section_header>
          </:header>
          <:note :if={@email_changeable?}>
            Sign-in codes for this workspace go to your email. To change it, confirm with your
            authenticator or a code sent to it, then with a code sent to the new address.
          </:note>
          <:note :if={@profile_loaded? and not @email_changeable? and not @profile_error?}>
            Your identity provider manages your email in this workspace.
          </:note>
          <p :if={@profile_error?} role="alert" class="mb-4 text-sm text-rose-300">
            Couldn't load your profile. Refresh to try again.
          </p>
          <.simple_form
            :if={@profile_editing?}
            for={@profile_form}
            id="profile-form"
            class="max-w-2xl"
            phx-change="validate_profile"
            phx-submit="save_profile"
            phx-mounted={JS.focus(to: "#profile_display_name")}
            phx-remove={JS.focus(to: "#change-name")}
          >
            <.input
              field={@profile_form[:display_name]}
              type="text"
              label="Display name"
              autocomplete="name"
              maxlength="255"
            />
            <:actions>
              <.button type="submit" phx-disable-with="Saving…">Save name</.button>
              <.button type="button" variant={:secondary} phx-click="cancel_profile">Cancel</.button>
            </:actions>
          </.simple_form>
          <dl :if={not @profile_editing?} class="divide-y divide-zinc-800/70">
            <div id="display-name" class="pb-4">
              <dt class="mb-1 text-sm text-zinc-400">Display name</dt>
              <dd class="flex items-center justify-between gap-4">
                <span class="min-w-0 break-words text-base text-zinc-100">
                  {@current_membership.display_name || "No display name"}
                </span>
                <.button
                  :if={@profile_editable?}
                  id="change-name"
                  variant={:secondary}
                  size={:sm}
                  phx-click="edit_profile"
                >
                  Change name
                </.button>
              </dd>
              <p
                :if={@profile_loaded? and not @profile_editable? and not @profile_error?}
                class="mt-2 text-xs text-zinc-400"
              >
                Your identity provider manages this name.
              </p>
            </div>
            <div id="email" class="pt-4">
              <dt class="mb-1 text-sm text-zinc-400">Email</dt>
              <%= case @email_step do %>
                <% :idle -> %>
                  <dd class="flex items-center justify-between gap-4">
                    <span class="min-w-0 break-all text-base text-zinc-100">
                      {@current_membership.email || "No email address"}
                    </span>
                    <.button
                      :if={@email_changeable?}
                      id="change-email"
                      variant={:secondary}
                      size={:sm}
                      phx-click="edit_email"
                    >
                      Change email
                    </.button>
                  </dd>
                  <p
                    :if={@current_membership.email && is_nil(@current_membership.email_verified_at)}
                    class="mt-2 text-xs text-zinc-400"
                  >
                    Not verified: you sign in to this workspace through single sign-on.
                  </p>
                <% :edit -> %>
                  <dd>
                    <.simple_form
                      for={@email_form}
                      id="email_form"
                      class="max-w-2xl"
                      phx-change="validate_email"
                      phx-submit="save_email"
                    >
                      <.input
                        field={@email_form[:email]}
                        type="email"
                        label="New email"
                        autocomplete="email"
                        required
                      />
                      <.error :if={@email_step_error}>{@email_step_error}</.error>
                      <:actions>
                        <.button type="submit" phx-disable-with="Checking…">Continue</.button>
                        <.button type="button" variant={:secondary} phx-click="cancel_email_change">
                          Cancel
                        </.button>
                      </:actions>
                    </.simple_form>
                  </dd>
                <% step -> %>
                  <dd>
                    <.simple_form
                      for={@email_step_form}
                      id="email_step_form"
                      class="max-w-2xl"
                      phx-submit="confirm_email_change"
                    >
                      <p class="text-sm text-zinc-300">
                        To change your email to <span class="break-all font-medium text-zinc-100">{@pending_new_email}</span>,
                        <%= case step do %>
                          <% :email -> %>
                            enter the 6-digit code sent to <span class="break-all">{@current_membership.email}</span>.
                          <% :mfa -> %>
                            enter a code from your authenticator app, or a recovery code.
                          <% :new_address -> %>
                            enter the 6-character code sent to that address. Your email stays the same until you finish.
                        <% end %>
                      </p>
                      <%= if step == :mfa do %>
                        <.input
                          field={@email_step_form[:code]}
                          type="text"
                          label="Authenticator or recovery code"
                          autocomplete="one-time-code"
                          required
                        />
                        <.error :if={@email_step_error}>{@email_step_error}</.error>
                      <% else %>
                        <.code_input
                          id={email_code_input_id(step)}
                          name="email_step[code]"
                          numeric={step != :new_address}
                          label="Code"
                          error={@email_step_error}
                        />
                      <% end %>
                      <:actions>
                        <.button type="submit" phx-disable-with="Checking…">
                          {if step == :new_address, do: "Change email", else: "Continue"}
                        </.button>
                        <.button
                          :if={step == :email}
                          type="button"
                          variant={:secondary}
                          phx-click="resend_email_code"
                        >
                          Resend code
                        </.button>
                        <.button type="button" variant={:secondary} phx-click="cancel_email_change">
                          Cancel
                        </.button>
                      </:actions>
                    </.simple_form>
                  </dd>
              <% end %>
            </div>
          </dl>
        </.section_with_note>

        <.section_with_note id="multi-factor-authentication">
          <:header>
            <.section_header title="Multi-factor authentication">
              <:subtitle>Use an authenticator app for an extra check when you sign in.</:subtitle>
            </.section_header>
          </:header>
          <:note :if={
            not is_nil(@mfa_facts) and not @mfa_facts.enabled? and @mfa_enrollment_step == :idle
          }>
            We recommend enabling MFA to help protect your account in this workspace.
          </:note>

          <%= cond do %>
            <% is_nil(@mfa_facts) -> %>
              <p role="status" class="text-sm text-zinc-400">Loading MFA settings…</p>
            <% @mfa_recovery_codes -> %>
              <.mfa_setup_progress :if={@mfa_enrollment_step == :recovery} step={3} />
              <.secret_reveal
                id="mfa-recovery-codes"
                title="Save your recovery codes"
                codes={@mfa_recovery_codes}
                download_name="emisar-recovery-codes.txt"
              >
                Use a recovery code if you can't access your authenticator. Each code works once.
                Save these somewhere safe. You won't be able to view them again.
                <:actions>
                  <.recovery_code_acknowledgement
                    saved={@codes_saved?}
                    event="dismiss_recovery_codes"
                  />
                </:actions>
              </.secret_reveal>
            <% @mfa_facts.enabled? -> %>
              <% remaining = @mfa_facts.recovery_codes_remaining %>
              <div
                id="mfa-status"
                class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between"
              >
                <div class="min-w-0">
                  <.chip tone={:brand}>Enabled</.chip>
                  <div class="mt-2 space-y-1 text-sm">
                    <p class="text-zinc-400">
                      <span class="tabular-nums">{remaining}</span>
                      recovery {if remaining == 1, do: "code", else: "codes"} remaining.
                    </p>
                    <p :if={remaining <= 2} class="text-amber-300">
                      Generate new codes before these run out.
                    </p>
                  </div>
                </div>
                <div
                  :if={@mfa_recovery_regeneration_step == :idle and @mfa_disable_step == :idle}
                  class="flex shrink-0 flex-wrap gap-2 sm:justify-end"
                >
                  <.button
                    id="regen-codes"
                    variant={:secondary}
                    size={:sm}
                    type="button"
                    phx-click="start_regenerate_recovery_codes"
                  >
                    Generate new recovery codes
                  </.button>
                  <.button
                    id="disable-mfa"
                    variant={:secondary}
                    tone={:rose}
                    size={:sm}
                    phx-click="start_disable_mfa"
                  >
                    Disable MFA
                  </.button>
                </div>
              </div>
              <.simple_form
                :if={@mfa_recovery_regeneration_step == :code}
                for={@mfa_recovery_regeneration_form}
                id="mfa_recovery_regeneration_form"
                phx-submit="regenerate_recovery_codes"
                class="mt-5 max-w-2xl"
              >
                <.section_header level={3} title="Generate new recovery codes">
                  <:subtitle>
                    New recovery codes will replace your existing codes. Enter an authenticator
                    or recovery code to continue.
                  </:subtitle>
                </.section_header>
                <.input
                  field={@mfa_recovery_regeneration_form[:code]}
                  type="text"
                  label="Authenticator or recovery code"
                  autocomplete="one-time-code"
                  required
                />
                <.error :if={@mfa_recovery_regeneration_error}>
                  {@mfa_recovery_regeneration_error}
                </.error>
                <:actions>
                  <.button phx-disable-with="Generating...">Generate new codes</.button>
                  <.button
                    variant={:ghost}
                    type="button"
                    phx-click="cancel_regenerate_recovery_codes"
                  >
                    Cancel
                  </.button>
                </:actions>
              </.simple_form>
              <.simple_form
                :if={@mfa_disable_step == :code}
                for={@mfa_disable_form}
                id="mfa_disable_form"
                phx-submit="disable_mfa"
                class="mt-5 max-w-2xl"
              >
                <.section_header level={3} title="Disable MFA">
                  <:subtitle>
                    You'll stop using an authenticator code to sign in to this workspace. If it
                    requires MFA, you'll set one up again on your next visit.
                  </:subtitle>
                </.section_header>
                <.input
                  field={@mfa_disable_form[:code]}
                  type="text"
                  label="Authenticator or recovery code"
                  autocomplete="one-time-code"
                  required
                />
                <.error :if={@mfa_disable_error}>{@mfa_disable_error}</.error>
                <:actions>
                  <.button variant={:secondary} tone={:rose} phx-disable-with="Disabling...">
                    Disable MFA
                  </.button>
                  <.button
                    variant={:ghost}
                    type="button"
                    phx-click="cancel_disable_mfa"
                  >
                    Cancel
                  </.button>
                </:actions>
              </.simple_form>
            <% @mfa_enrollment_step == :email -> %>
              <.mfa_setup_progress step={1} />
              <.mfa_enrollment_email_verification
                email={@current_membership.email}
                form={@mfa_enrollment_email_form}
                error={@mfa_enrollment_email_error}
              >
                <:actions>
                  <.button phx-disable-with="Verifying...">Verify email</.button>
                  <%!-- Resending sends a real email — a bordered face (§7.47), so it
                       doesn't read as a second Cancel beside the actual one. --%>
                  <.button
                    variant={:secondary}
                    type="button"
                    phx-click="resend_mfa_enrollment_email"
                  >
                    Resend code
                  </.button>
                  <.button variant={:ghost} type="button" phx-click="cancel_mfa">
                    Cancel
                  </.button>
                </:actions>
              </.mfa_enrollment_email_verification>
            <% @mfa_enrollment_step == :totp -> %>
              <.mfa_setup_progress step={2} />
              <.mfa_enrollment
                qr_svg={@mfa_qr_svg}
                setup_key={@mfa_setup_key}
                form={@mfa_form}
                variant={:split}
                error={@mfa_error}
              >
                <:instructions>
                  Scan this QR code with your authenticator app, then enter its 6-digit code.
                </:instructions>
                <:actions>
                  <.button phx-disable-with="Enabling...">Enable MFA</.button>
                  <.button variant={:ghost} type="button" phx-click="cancel_mfa">
                    Cancel
                  </.button>
                </:actions>
              </.mfa_enrollment>
            <% @mfa_facts.enrollment_proof == :email -> %>
              <div id="mfa-status" class="flex flex-wrap items-center justify-between gap-4">
                <.chip tone={:amber}>Not enabled</.chip>
                <.button
                  variant={:primary}
                  phx-click="start_mfa"
                  phx-disable-with="Sending…"
                  size={:sm}
                >
                  Set up MFA
                </.button>
              </div>
              <.error :if={@mfa_start_error}>{@mfa_start_error}</.error>
            <% @mfa_facts.enrollment_proof == :sso -> %>
              <%!-- An SSO-only Member proves itself with a fresh sign-in at its identity
                   provider; the callback continues enrollment on the MFA setup page. --%>
              <div id="mfa-status" class="flex flex-wrap items-center justify-between gap-4">
                <.chip tone={:amber}>Not enabled</.chip>
                <.button
                  id="verify-with-sso"
                  href={~p"/app/#{@current_account}/mfa_setup/sso"}
                  method="post"
                  size={:sm}
                >
                  Verify with {sso_provider_name(@current_auth)}
                </.button>
              </div>
              <p class="mt-3 text-sm text-zinc-400">
                To set up MFA, first sign in again with {sso_provider_name(@current_auth)} to confirm
                it's you.
              </p>
            <% true -> %>
              <div id="mfa-status" class="flex flex-wrap items-center justify-between gap-4">
                <.chip tone={:amber}>Not enabled</.chip>
              </div>
              <p class="mt-3 text-sm text-zinc-400">
                Setting up an authenticator needs a fresh proof of your own sign-in: a code to a
                verified email address, or a new sign-in through this workspace's identity provider.
                Neither is available from this session. Ask a workspace administrator for help.
              </p>
          <% end %>
        </.section_with_note>

        <.section_with_note id="sessions">
          <:header>
            <.section_header title="Active sessions">
              <:subtitle>
                Browsers and devices signed in to
                <span class="font-medium text-zinc-200">{@current_account.name}</span>
                as you.
              </:subtitle>
              <:actions>
                <.confirm_button
                  :if={@session_count > 1}
                  id="signout-others"
                  title="Sign out of every other browser and device?"
                  confirm_label="Sign out everywhere else"
                  variant={:secondary}
                  tone={:rose}
                  size={:sm}
                  on_confirm={JS.push("revoke_other_sessions")}
                >
                  <:body>Your current device stays signed in.</:body>
                  Sign out everywhere else
                </.confirm_button>
              </:actions>
            </.section_header>
          </:header>
          <:note>
            <p>
              Don't recognize a session? Sign it out. That browser or device will need to sign in again.
              Signing out everywhere else keeps this session open.
            </p>
            <p :if={ApiKeys.subject_can_view_api_keys?(@current_subject)} class="mt-4">
              <.link
                id="review-your-agents"
                navigate={
                  ~p"/app/#{@current_account}/agents?#{[owner: @current_subject.membership_id]}"
                }
                class="group text-brand-400 hover:text-brand-300"
              >Review your agents in this workspace&nbsp;<.cta_arrow /></.link>
            </p>
          </:note>

          <%!-- No max-height: the scroll cap cropped the next row to a ~10px
               sliver that read as a rendering bug. Long lists paginate (10 a
               page) instead of scrolling, so "Sign out everywhere else" and the
               pager below carry the long-list affordance. space-y-4 spaces the
               pager off the list only when the pager renders (its :if drops the
               node on a single page, leaving one child and no phantom gap). --%>
          <div class="space-y-4">
            <p
              :if={not @sessions_loaded?}
              role="status"
              class="text-sm text-zinc-400"
            >
              Loading sessions…
            </p>
            <.empty_state
              :if={@sessions_error?}
              tone={:danger}
              icon="state.warning"
              title="Couldn't load your sessions"
            >
              Try loading them again.
              <:actions>
                <.button
                  variant={:secondary}
                  size={:sm}
                  phx-click="retry_sessions"
                  phx-disable-with="Loading…"
                >
                  Retry
                </.button>
              </:actions>
            </.empty_state>

            <ul
              :if={@sessions_loaded? and not @sessions_error?}
              id="active-sessions"
              phx-update="stream"
              class="divide-y divide-zinc-800/70 text-sm"
            >
              <.list_row
                :for={{dom_id, session} <- @streams.sessions}
                id={dom_id}
                icon={session.icon}
                meta_wrap
              >
                <:title>
                  <span class="truncate font-medium text-zinc-100">
                    {session.device_label}
                  </span>
                </:title>
                <:chips>
                  <.chip :if={session.current?} tone={:neutral}>
                    This session
                  </.chip>
                </:chips>
                <:meta>
                  <p>
                    Signed in
                    <.local_time
                      id={"session-started-#{session.id}"}
                      value={session.inserted_at}
                      mode={:absolute}
                      styled_tooltip
                    /><span :if={session.sign_in_method}> · {session.sign_in_method}</span>
                  </p>
                  <p class="mt-1">
                    Sign-in IP:
                    <span class="break-all font-mono">{session.ip_address || "Not recorded"}</span>
                  </p>
                </:meta>
                <:actions>
                  <%!-- Neutral, not rose — a routine self-service sign-out shouldn't
                     read as dangerous as the account-wide "Sign out everywhere else"
                     (which keeps the danger tone). --%>
                  <.confirm_button
                    :if={not session.current?}
                    id={"signout-session-#{session.id}"}
                    title="Sign out this session?"
                    confirm_label="Sign out"
                    variant={:secondary}
                    tone={:neutral}
                    size={:sm}
                    class="shrink-0"
                    on_confirm={JS.push("revoke_session", value: %{id: session.id})}
                  >
                    <:body>That browser or device will need to sign in again.</:body>
                    Sign out
                  </.confirm_button>
                </:actions>
              </.list_row>
            </ul>

            <%!-- Renders only past one page (metadata cursors / count > page) —
               a handful of sessions stays a plain list, no pager chrome. --%>
            <LiveTable.paginator
              id="active-sessions"
              path={~p"/app/#{@current_account}/settings/profile"}
              metadata={@metadata}
              filter_params={@filter_params}
              page_count={@session_page_count}
            />
          </div>
        </.section_with_note>
      </div>
    </.console_shell>
    """
  end
end
