defmodule EmisarWeb.ProfileLive do
  use EmisarWeb, :live_view
  alias Emisar.{Auth, SSO, Users}
  alias EmisarWeb.{ConfirmDialog, LiveForm, LiveTable, MfaEnrollment}
  alias EmisarWeb.{MfaErrors, OIDCStepUp, UserAgent}
  alias Phoenix.LiveView.JS

  # Both step-ups on this page — the email-change authenticator branch and
  # disabling MFA — spend the same per-user MFA attempt window, so they report
  # its exhaustion in the same words.
  @mfa_enrollment_email_unavailable_error "Your profile has no email address. Ask your workspace administrator for help, or contact support@emisar.dev."
  @mfa_enrollment_email_suppressed_error "Emisar cannot deliver mail to your current address. Contact support to restore email delivery before setting up MFA."
  @mfa_enrollment_email_delivery_error "We could not deliver the verification code. Try again. If it keeps failing, contact support."

  # Named once so linking and removing a sign-in method report an unstartable
  # step-up identically — the operator hit the same wall either way.
  @oidc_step_up_start_error "Couldn't start confirmation. Try again."

  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, "Profile")
     |> assign(:profile_editing?, false)
     |> assign(:mfa_recovery_codes, nil)
     |> assign(:codes_saved?, false)
     |> assign(:mfa_start_error, nil)
     |> assign(:mfa_recovery_regeneration_step, :idle)
     |> assign(:mfa_recovery_regeneration_error, nil)
     |> assign(:mfa_disable_step, :idle)
     |> assign(:mfa_disable_error, nil)
     |> assign(:session_count, 0)
     |> assign(:session_page_count, 0)
     |> assign(:metadata, %Emisar.Repo.Paginator.Metadata{count: 0, limit: 0})
     |> assign(:filter_params, %{})
     |> assign(:sessions_error?, false)
     |> assign(:sessions_loaded?, false)
     |> assign(:oidc_identities, [])
     |> assign(:oidc_identities_error?, false)
     |> assign(:oidc_identities_loaded?, false)
     |> OIDCStepUp.reset()
     |> ConfirmDialog.init()
     |> assign_mfa_facts(user)
     |> assign_profile_form(user)
     |> assign_email_form(user)
     |> MfaEnrollment.reset()
     |> assign_mfa_enrollment_email_form()
     |> assign_mfa_form()
     |> assign_mfa_recovery_regeneration_form()
     |> assign_mfa_disable_form()
     |> reset_email_step()
     |> stream(:sessions, [])}
  end

  def handle_params(params, _uri, socket), do: {:noreply, maybe_load_sessions(socket, params)}

  # IL-18: load lists only after connecting; static HTML shows loading, not an
  # empty result. Session pagination preserves its URL state.
  defp maybe_load_sessions(socket, params) do
    if connected?(socket) do
      socket |> load_sessions(params) |> load_oidc_identities()
    else
      assign(socket, :filter_params, params)
    end
  end

  defp load_oidc_identities(socket) do
    socket = assign(socket, :oidc_identities_loaded?, true)

    case SSO.list_self_service_identity_facts(socket.assigns.current_subject) do
      {:ok, identities} ->
        socket
        |> assign(:oidc_identities, identities)
        |> assign(:oidc_identities_error?, false)

      {:error, _reason} ->
        socket
        |> assign(:oidc_identities, [])
        |> assign(:oidc_identities_error?, true)
    end
  end

  # 10 a page: a heavy automation account can hold ~100 sessions, and an
  # ungrouped wall of near-identical rows buries the one unfamiliar device an
  # operator is scanning for. Cursor-paginated (UserToken.Query.cursor_fields).
  defp load_sessions(socket, params) do
    socket = assign(socket, :sessions_loaded?, true)
    opts = LiveTable.params_to_opts(params)
    list_opts = Keyword.put(opts, :page, Keyword.put(opts[:page], :limit, 10))

    presented_digest = socket.assigns.current_auth.token

    case Auth.list_sessions_for_user(presented_digest, socket.assigns.current_subject, list_opts) do
      {:ok, sessions, metadata} ->
        presented = Enum.map(sessions, &present_session/1)

        socket
        |> assign(:session_count, metadata.count || 0)
        |> assign(:session_page_count, length(presented))
        |> assign(:metadata, metadata)
        |> assign(:filter_params, params)
        |> assign(:sessions_error?, false)
        |> stream(:sessions, presented, reset: true)

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
      device_label: UserAgent.label(session.user_agent),
      icon: UserAgent.icon(session.user_agent),
      current?: session.current?,
      ip_address: session_ip(session.ip_address),
      inserted_at: session.inserted_at
    }
  end

  def handle_event("edit_profile", _params, socket) do
    {:noreply,
     socket
     |> assign_profile_form(socket.assigns.current_user)
     |> assign(:profile_editing?, true)}
  end

  def handle_event("cancel_profile_edit", _params, socket) do
    {:noreply,
     socket
     |> assign_profile_form(socket.assigns.current_user)
     |> assign(:profile_editing?, false)}
  end

  def handle_event("validate_profile", %{"profile" => params} = event, socket) do
    changeset =
      socket.assigns.current_user
      |> Users.change_user(params)
      |> LiveForm.on_change(event)

    {:noreply, assign(socket, :profile_form, to_form(changeset, as: "profile"))}
  end

  def handle_event("save_profile", %{"profile" => params}, socket) do
    case Users.update_user_profile(params, socket.assigns.current_subject) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "Name updated.")
         |> assign(:current_user, updated)
         |> assign(:profile_editing?, false)
         |> assign_profile_form(updated)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :profile_form, to_form(changeset, as: "profile"))}

      {:error, _reason} ->
        changeset = Users.change_user(socket.assigns.current_user, params)

        {:noreply,
         socket
         |> assign(:profile_form, to_form(changeset, as: "profile"))
         |> put_flash(:error, "Couldn't update your name. Try again.")}
    end
  end

  def handle_event("validate_email", %{"email" => params} = event, socket) do
    changeset =
      socket.assigns.current_user
      |> Users.change_user(%{"email" => params["email"] || ""})
      |> LiveForm.on_change(event)

    socket =
      if socket.assigns.email_step == :edit and
           params["email"] != socket.assigns.email_form[:email].value do
        assign(socket, :email_step_error, nil)
      else
        socket
      end

    {:noreply, assign(socket, :email_form, to_form(changeset, as: "email"))}
  end

  def handle_event("edit_email", _params, socket) do
    {:noreply,
     socket
     |> reset_email_step()
     |> assign(:email_step, :edit)
     |> assign_email_form(socket.assigns.current_user)}
  end

  def handle_event("retry_sessions", _params, socket),
    do: {:noreply, reload_sessions(socket)}

  def handle_event("retry_oidc_identities", _params, socket),
    do: {:noreply, load_oidc_identities(socket)}

  # Email is identity-defining — it controls every future magic link — so a
  # self-service change is credential-grade: the submit only STARTS a step-up
  # (an MFA-on user re-enters a TOTP code; everyone else confirms a one-time
  # code emailed to their CURRENT address) and the change commits only after
  # `confirm_email_change` verifies it. A stolen session alone — no second
  # factor, no inbox — can't pass it.
  def handle_event("save_email", %{"email" => params}, socket) do
    user = socket.assigns.current_user
    new_email = String.trim(params["email"] || "")
    changeset = Users.change_user(user, %{"email" => new_email})

    cond do
      not changeset.valid? ->
        changeset = Map.put(changeset, :action, :validate)
        {:noreply, assign(socket, :email_form, to_form(changeset, as: "email"))}

      not Map.has_key?(changeset.changes, :email) ->
        {:noreply, assign(socket, :email_step_error, "That's already your email.")}

      true ->
        {:noreply, start_email_step_up(socket, user, new_email)}
    end
  end

  def handle_event("confirm_email_change", %{"email_step" => %{"code" => code}}, socket) do
    %{email_step: step, pending_new_email: new_email, current_subject: subject} = socket.assigns

    # Sequencing guard is the web's own state; the step-up factor decision, the
    # verify, and the commit are all `Auth.confirm_email_change`'s call — the
    # domain re-derives the factor from the fresh row and gates the write.
    if step in [:totp, :code] do
      handle_email_change_confirmation(socket, new_email, String.trim(code || ""), subject, step)
    else
      # Out-of-sequence (fired over the socket while :idle, before any save_email
      # started a step-up) — fail closed (IL-15: a handler is reachable over the
      # socket regardless of what's rendered).
      {:noreply, put_flash(socket, :error, "Start an email change first.")}
    end
  end

  def handle_event("resend_email_code", _params, socket) do
    %{email_step: step, pending_new_email: new_email} = socket.assigns

    # Same fail-closed sequencing guard as confirm_email_change (IL-15): resend
    # only makes sense while an emailed-code step-up is pending.
    if step == :code do
      case Auth.issue_email_change_code(new_email, socket.assigns.current_subject) do
        {:ok, :sent} ->
          {:noreply,
           socket
           |> assign(:email_step_error, nil)
           |> push_event("code:reset", %{id: "email-step-code"})
           |> put_flash(:info, "We sent a new code to #{socket.assigns.current_user.email}.")}

        # The code goes to the CURRENT address, which has bounced/complained, so
        # no code will arrive and the change can't complete — say so plainly.
        {:ok, :suppressed} ->
          {:noreply,
           assign(
             socket,
             :email_step_error,
             "We can't send a code to your current email (#{socket.assigns.current_user.email}). Contact support@emisar.dev."
           )}

        {:error, :rate_limited} ->
          {:noreply, assign(socket, :email_step_error, MfaErrors.message(:email_rate_limited))}

        # :not_found (row gone mid-session) or any other unexpected Multi failure.
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
     |> assign_email_form(socket.assigns.current_user)
     |> reset_email_step()}
  end

  def handle_event("start_oidc_link", %{"provider_id" => provider_id}, socket) do
    socket = socket |> OIDCStepUp.reset() |> ConfirmDialog.reset()

    case Enum.find(socket.assigns.oidc_identities, &(&1.provider_id == provider_id)) do
      %{linked?: false} = identity ->
        {:noreply, OIDCStepUp.begin(socket, identity, :link, @oidc_step_up_start_error)}

      %{linked?: true, user_verified?: false} = identity ->
        {:noreply, OIDCStepUp.begin(socket, identity, :link, @oidc_step_up_start_error)}

      %{linked?: true, user_verified?: true} ->
        {:noreply, put_flash(socket, :info, "That sign-in method is already linked.")}

      nil ->
        {:noreply, put_flash(socket, :error, "That sign-in method is no longer available.")}
    end
  end

  def handle_event("start_oidc_unlink", %{"identity_id" => identity_id}, socket)
      when is_binary(identity_id) do
    socket = socket |> OIDCStepUp.reset() |> ConfirmDialog.reset()

    case Enum.find(socket.assigns.oidc_identities, &(&1.identity_id == identity_id)) do
      %{removable?: true} = identity ->
        {:noreply, OIDCStepUp.begin(socket, identity, :unlink, @oidc_step_up_start_error)}

      %{removal_blocked_reason: :required_sso_identity} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Link another enabled sign-in method before removing this one."
         )}

      %{linked?: true} ->
        {:noreply,
         put_flash(socket, :error, "Verify this sign-in method yourself before removing it.")}

      # No match (nil) or a matched-but-unlinked identity (a retired provider still
      # in the list) — either way there is nothing linked to remove.
      _ ->
        {:noreply, put_flash(socket, :error, "That sign-in method is no longer linked.")}
    end
  end

  def handle_event("start_oidc_unlink", _params, socket), do: {:noreply, socket}

  def handle_event("confirm_oidc_step_up", %{"oidc_step" => %{"code" => code}} = params, socket) do
    case socket.assigns.oidc_step do
      %{} = step ->
        if step.purpose == :unlink and params["confirm_token"] != step.provider_name do
          {:noreply,
           assign(socket, :oidc_step_error, "Enter the provider name to confirm removal.")}
        else
          case OIDCStepUp.confirm(step, code, socket.assigns.current_subject) do
            {:ok, proof} ->
              complete_oidc_step_up(socket, step, proof)

            {:error, message} ->
              {:noreply,
               socket
               |> assign(:oidc_step_error, message)
               |> push_event("code:reset", %{id: "profile-oidc-step-code"})}
          end
        end

      nil ->
        {:noreply, put_flash(socket, :error, "Choose a sign-in method first.")}
    end
  end

  def handle_event("resend_oidc_step_up", _params, socket) do
    case socket.assigns.oidc_step do
      %{factor: :email} = step ->
        {:noreply, OIDCStepUp.resend(socket, step, "profile-oidc-step-code")}

      _other ->
        {:noreply, put_flash(socket, :error, "Start the confirmation again.")}
    end
  end

  def handle_event("cancel_oidc_step_up", _params, socket),
    do: {:noreply, socket |> OIDCStepUp.reset() |> ConfirmDialog.reset()}

  def handle_event("confirm_typed", params, socket),
    do: {:noreply, ConfirmDialog.put_typed(socket, params)}

  def handle_event("confirm_reset", _params, socket),
    do: {:noreply, ConfirmDialog.reset(socket)}

  def handle_event("revoke_session", %{"id" => id}, socket) do
    case Auth.revoke_session(id, socket.assigns.current_subject) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Session signed out.") |> reload_sessions()}

      {:error, :not_found} ->
        {:noreply,
         socket |> put_flash(:info, "This session has already ended.") |> reload_sessions()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't sign out this session. Try again.")}
    end
  end

  def handle_event("revoke_other_sessions", _params, socket) do
    keep_digest = socket.assigns.current_auth.token

    revoked_count =
      Auth.revoke_and_disconnect_other_sessions!(keep_digest, socket.assigns.current_subject)

    msg =
      case revoked_count do
        0 -> "No other sessions to sign out."
        _revoked -> "Other sessions signed out."
      end

    # Only the current session survives, and it's always on page 1 — land there
    # rather than reloading a now-empty cursor the operator was paging through.
    {:noreply, socket |> put_flash(:info, msg) |> load_sessions(%{})}
  end

  def handle_event("start_mfa", _params, socket) do
    case Auth.issue_mfa_enrollment_code(socket.assigns.current_subject) do
      {:ok, :sent} ->
        {:noreply,
         socket
         |> assign(:mfa_enrollment_step, :email)
         |> assign(:mfa_start_error, nil)
         |> assign(:mfa_enrollment_email_error, nil)
         |> put_flash(:info, "We emailed a verification code to your current address.")}

      {:ok, :suppressed} ->
        {:noreply, assign(socket, :mfa_start_error, @mfa_enrollment_email_suppressed_error)}

      {:error, :rate_limited} ->
        {:noreply, assign(socket, :mfa_start_error, MfaErrors.message(:email_rate_limited))}

      {:error, :email_unavailable} ->
        {:noreply, assign(socket, :mfa_start_error, @mfa_enrollment_email_unavailable_error)}

      {:error, :mfa_already_enabled} ->
        {:noreply, refresh_after_mfa_enabled(socket)}

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
           assign(
             socket,
             :mfa_enrollment_email_error,
             "That code is incorrect or expired. Try again or request a new code."
           )}

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
             "MFA enabled. Copy your recovery codes below — they'll only be shown once."
           )
           |> assign(:current_user, updated)
           |> MfaEnrollment.assign_current_proof(updated)
           |> assign_mfa_facts(updated)
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

        {:error, :session_not_found} ->
          {:noreply,
           socket
           |> put_flash(:error, MfaErrors.message(:session_not_found))
           |> push_navigate(to: ~p"/sign_in/magic")}

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
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "MFA disabled.")
         |> assign(:current_user, updated)
         |> assign_mfa_facts(updated)
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
      {:ok, updated, codes} ->
        {:noreply,
         socket
         |> put_flash(:info, "New recovery codes generated. Old codes are now invalid.")
         |> assign(:current_user, updated)
         |> assign_mfa_facts(updated)
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

  # The subject carries a mount-time actor snapshot, so every credential write
  # re-derives the facts from the fresh user row the domain handed back — the
  # page itself never inspects an MFA field.
  defp assign_mfa_facts(socket, user) do
    {:ok, facts} = Auth.mfa_facts(%{socket.assigns.current_subject | actor: user})
    assign(socket, :mfa_facts, facts)
  end

  defp assign_profile_form(socket, user) do
    changeset = Users.change_user(user, %{"full_name" => user.full_name || ""})
    assign(socket, :profile_form, to_form(changeset, as: "profile"))
  end

  defp assign_email_form(socket, user) do
    changeset = Users.change_user(user, %{"email" => user.email || ""})
    assign(socket, :email_form, to_form(changeset, as: "email"))
  end

  # Email-change state: :idle (current address), :edit (new address), :totp (an MFA-on user
  # re-enters an authenticator code), or :code (a one-time code emailed to the
  # current address). `pending_new_email` is the change awaiting confirmation.
  defp reset_email_step(socket) do
    socket
    |> assign(:email_step, :idle)
    |> assign(:pending_new_email, nil)
    |> assign(:email_step_error, nil)
    |> assign(:email_step_form, to_form(%{"code" => ""}, as: "email_step"))
  end

  defp handle_email_change_confirmation(socket, new_email, code, subject, step) do
    socket = push_event(socket, "code:reset", %{id: "email-step-code"})

    case Auth.confirm_email_change(new_email, code, subject) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "Email changed. Check #{updated.email} for a confirmation link.")
         |> assign(:current_user, updated)
         |> assign_email_form(updated)
         |> reset_email_step()}

      # Capped before the code was even checked — the step-up stays open so the
      # operator can retry once the window rolls over.
      {:error, :rate_limited} ->
        {:noreply, assign(socket, :email_step_error, MfaErrors.message(:rate_limited))}

      {:error, :replay} ->
        {:noreply,
         assign(
           socket,
           :email_step_error,
           "That code was just used — wait a moment for the next one."
         )}

      {:error, :invalid} ->
        {:noreply, assign(socket, :email_step_error, step_up_error(step))}

      # Step-up passed but the email itself was rejected (e.g. now taken) — the
      # one-time proof is spent, so send them back to the start.
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> reset_email_step()
         |> assign(:email_step, :edit)
         |> assign(:email_form, to_form(changeset, as: "email"))
         |> assign(
           :email_step_error,
           "Couldn't change to that email. Check the address and try again."
         )}

      # Any other domain failure (e.g. the row was soft-deleted mid-session) — the
      # proof is spent, so reset rather than leave a dead step-up open.
      {:error, _reason} ->
        {:noreply,
         socket
         |> reset_email_step()
         |> assign(:email_step, :edit)
         |> assign(:email_step_error, "Couldn't change your email. Try again.")}
    end
  end

  # The DOMAIN decides the factor from the user's CURRENT row (`begin_email_change`
  # re-reads it) — not `@mfa_facts`, which is a stale mount snapshot that could
  # downgrade the challenge — and issues the emailed code on the `:code` path.
  defp start_email_step_up(socket, user, new_email) do
    # A fresh challenge invalidates any rejection from a prior one — a stale
    # inline error under a brand-new code input would accuse the operator of a
    # mistake they haven't made yet.
    socket =
      socket
      |> assign(:pending_new_email, new_email)
      |> assign(:email_step_error, nil)

    case Auth.begin_email_change(new_email, socket.assigns.current_subject) do
      {:ok, :totp} ->
        assign(socket, :email_step, :totp)

      {:ok, :code} ->
        socket
        |> assign(:email_step, :code)
        |> put_flash(:info, "We emailed a confirmation code to #{user.email}.")

      # The code goes to the CURRENT address to prove inbox control; that address
      # has bounced/complained, so no code will arrive — say so instead of a false
      # "check your inbox". They can't self-fix a suppressed current address.
      {:error, :delivery_suppressed} ->
        socket
        |> assign(:email_step, :edit)
        |> assign(
          :email_step_error,
          "We can't send a code to your current email (#{user.email}). Contact support@emisar.dev."
        )

      {:error, :email_unavailable} ->
        socket
        |> assign(:email_step, :edit)
        |> assign(:email_step_error, @mfa_enrollment_email_unavailable_error)

      {:error, :rate_limited} ->
        socket
        |> assign(:email_step, :edit)
        |> assign(:email_step_error, MfaErrors.message(:email_rate_limited))

      # :not_found (row gone mid-session) or any other unexpected Multi failure.
      {:error, _reason} ->
        socket
        |> assign(:email_step, :edit)
        |> assign(:email_step_error, "Couldn't start the email change. Try again.")
    end
  end

  defp step_up_error(:totp), do: MfaErrors.message(:invalid_otp)

  defp step_up_error(_),
    do: "That code is incorrect or expired. Try again or request a new code."

  defp complete_oidc_step_up(socket, %{purpose: :unlink} = step, proof) do
    case SSO.unlink_identity(
           step.identity_id,
           proof,
           socket.assigns.current_auth.token,
           socket.assigns.current_subject
         ) do
      {:ok, _identity} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{step.provider_name} was removed from your profile.")
         |> OIDCStepUp.reset()
         |> load_oidc_identities()}

      {:error, :required_sso_identity} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Link another enabled sign-in method before removing the one this workspace requires."
         )
         |> OIDCStepUp.reset()}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Couldn't remove that sign-in method. Refresh and try again.")
         |> OIDCStepUp.reset()}
    end
  end

  defp complete_oidc_step_up(socket, %{purpose: :link} = step, proof),
    do: {:noreply, OIDCStepUp.handoff(socket, step, proof)}

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

  # No-op for the broadcasts the on_mount badge/fleet hooks forward (approvals,
  # pack trust, runner presence). The hooks own those nav cues; this page ignores them.
  def handle_info(_msg, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <.console_shell
      chrome={@shell_chrome}
      current_membership={@current_membership}
      current_subject={@current_subject}
      current_user={@current_user}
      current_account={@current_account}
      section={:profile}
      width={:table}
    >
      <:title>Profile</:title>

      <.page_intro>
        Your identity and sign-in security — the same across every workspace you belong to.
        <.doc_link href="/security">Security overview</.doc_link>
      </.page_intro>

      <div
        id="profile-layout"
        class="grid grid-cols-1 gap-x-12 gap-y-12 xl:grid-cols-[minmax(0,1fr)_18rem] xl:items-start"
      >
        <.section_with_note id="personal-details">
          <:header>
            <.section_header title="Personal details" />
          </:header>
          <dl class="divide-y divide-zinc-800/70">
            <div id="display-name" class="pb-4">
              <dt class="mb-1 text-sm text-zinc-400">Display name</dt>
              <dd>
                <div
                  :if={not @profile_editing?}
                  class="flex flex-wrap items-center justify-between gap-3"
                >
                  <p class="min-w-0 break-words text-base text-zinc-100">
                    {@current_user.full_name || "No display name"}
                  </p>
                  <.button id="change-name" variant={:secondary} size={:sm} phx-click="edit_profile">
                    Change name
                  </.button>
                </div>
                <.simple_form
                  :if={@profile_editing?}
                  for={@profile_form}
                  id="profile_form"
                  class="max-w-2xl"
                  phx-change="validate_profile"
                  phx-submit="save_profile"
                  phx-mounted={JS.focus(to: "#profile_full_name")}
                  phx-remove={JS.focus(to: "#change-name")}
                >
                  <%!-- No repeated field label — the row already says "Display name"
                 (one voice on a single-field section); aria-label keeps the
                 accessible name. --%>
                  <.input
                    field={@profile_form[:full_name]}
                    type="text"
                    aria-label="Display name"
                    autocomplete="name"
                    placeholder="Ada Lovelace"
                  />
                  <:actions>
                    <.button
                      variant={if @profile_form.source.changes == %{}, do: :secondary, else: :primary}
                      disabled={@profile_form.source.changes == %{}}
                      phx-disable-with="Saving..."
                    >
                      Save
                    </.button>
                    <.button variant={:ghost} type="button" phx-click="cancel_profile_edit">
                      Cancel
                    </.button>
                  </:actions>
                </.simple_form>
              </dd>
            </div>
            <div id="email" class="pt-4">
              <dt class="mb-1 text-sm text-zinc-400">Email</dt>
              <dd>
                <%= case @email_step do %>
                  <% :idle -> %>
                    <div class="flex flex-wrap items-center justify-between gap-3">
                      <div class="min-w-0">
                        <p class="break-all text-base text-zinc-100">
                          {@current_user.email || "No email address"}
                        </p>
                        <p
                          :if={is_nil(@current_user.email) and is_nil(@current_user.mfa_enabled_at)}
                          class="mt-1 text-xs text-zinc-400"
                        >
                          Your profile has no email address. Ask your workspace administrator for help,
                          or contact support@emisar.dev.
                        </p>
                        <p
                          :if={@current_user.email && is_nil(@current_user.confirmed_at)}
                          class="mt-1 text-xs text-zinc-400"
                        >
                          Awaiting confirmation
                        </p>
                      </div>
                      <.button
                        id="change-email"
                        variant={:secondary}
                        size={:sm}
                        phx-click="edit_email"
                        disabled={
                          is_nil(@current_user.email) and is_nil(@current_user.mfa_enabled_at)
                        }
                      >
                        Change email
                      </.button>
                    </div>
                  <% :edit -> %>
                    <.simple_form
                      for={@email_form}
                      id="email_form"
                      class="max-w-2xl"
                      phx-change="validate_email"
                      phx-submit="save_email"
                    >
                      <p class="text-sm text-zinc-300">Enter your new email address.</p>
                      <.input
                        field={@email_form[:email]}
                        type="email"
                        aria-label="New email address"
                        autocomplete="email"
                        required
                      />
                      <.error :if={@email_step_error}>{@email_step_error}</.error>
                      <:actions>
                        <.button
                          variant={
                            if @email_form.source.changes == %{}, do: :secondary, else: :primary
                          }
                          disabled={@email_form.source.changes == %{}}
                          phx-disable-with="Checking..."
                        >
                          Continue
                        </.button>
                        <.button variant={:ghost} type="button" phx-click="cancel_email_change">
                          Cancel
                        </.button>
                      </:actions>
                    </.simple_form>
                  <% step -> %>
                    <.simple_form
                      for={@email_step_form}
                      id="email_step_form"
                      class="max-w-2xl"
                      phx-submit="confirm_email_change"
                    >
                      <p class="text-sm text-zinc-300">
                        To change your email to <span class="break-all font-medium text-zinc-100">{@pending_new_email}</span>,
                        <%= if step == :code do %>
                          enter the 6-digit code sent to <span class="break-all">{@current_user.email}</span>.
                        <% else %>
                          enter the 6-digit code from your authenticator app.
                        <% end %>
                      </p>
                      <.code_input
                        id="email-step-code"
                        name="email_step[code]"
                        numeric
                        label={if step == :totp, do: "Authenticator code", else: "Confirmation code"}
                        error={@email_step_error}
                      />
                      <:actions>
                        <.button phx-disable-with="Changing...">Change email</.button>
                        <.button
                          :if={step == :code}
                          variant={:secondary}
                          size={:md}
                          type="button"
                          phx-click="resend_email_code"
                        >
                          Resend code
                        </.button>
                        <.button
                          variant={:ghost}
                          size={:md}
                          type="button"
                          phx-click="cancel_email_change"
                        >
                          Cancel
                        </.button>
                      </:actions>
                    </.simple_form>
                <% end %>
              </dd>
            </div>
          </dl>
        </.section_with_note>

        <.section_with_note id="single-sign-on">
          <:header>
            <.section_header title="Sign-in methods">
              <:subtitle>
                Sign-in methods you can link to your profile in this workspace.
              </:subtitle>
            </.section_header>
          </:header>
          <:note>
            Link the methods you use to help avoid approval delays.
            Each workspace sets its own sign-in rules.
            <.doc_link href="/docs/sso">About single sign-on</.doc_link>
          </:note>

          <p :if={not @oidc_identities_loaded?} role="status" class="text-sm text-zinc-400">
            Loading sign-in methods…
          </p>

          <.empty_state
            :if={@oidc_identities_error?}
            tone={:danger}
            icon="state.warning"
            title="Couldn't load sign-in methods"
          >
            Try loading them again.
            <:actions>
              <.button
                variant={:secondary}
                size={:sm}
                phx-click="retry_oidc_identities"
                phx-disable-with="Loading…"
              >
                Retry
              </.button>
            </:actions>
          </.empty_state>

          <p
            :if={@oidc_identities_loaded? and not @oidc_identities_error? and @oidc_identities == []}
            class="text-sm text-zinc-400"
          >
            No single sign-on providers are enabled in this workspace.
          </p>

          <ul
            :if={@oidc_identities != []}
            id="oidc-identities"
            class="divide-y divide-zinc-800/70 border-y border-zinc-800/70"
          >
            <li
              :for={identity <- @oidc_identities}
              id={"oidc-identity-#{identity.provider_id}"}
              class="flex flex-col gap-3 py-4 sm:flex-row sm:items-center sm:justify-between"
            >
              <div class="min-w-0">
                <p class="font-medium text-zinc-100">{identity.provider_name}</p>
                <p class="mt-1 text-xs text-zinc-400">
                  <%= cond do %>
                    <% identity.user_verified? -> %>
                      Linked by you
                    <% identity.linked? -> %>
                      Linked by your workspace
                    <% true -> %>
                      Not linked
                  <% end %>
                </p>
              </div>
              <div class="flex flex-wrap items-center gap-2 sm:justify-end">
                <span
                  :if={identity.linked? and not identity.user_verified?}
                  class="text-xs text-zinc-400"
                >
                  Verify it before you can remove it.
                </span>
                <.button
                  :if={not identity.user_verified?}
                  id={"link-oidc-#{identity.provider_id}"}
                  type="button"
                  variant={:secondary}
                  size={:sm}
                  class="min-w-20"
                  phx-hook="PendingButton"
                  phx-click="start_oidc_link"
                  phx-value-provider_id={identity.provider_id}
                  phx-disable-with={if(identity.linked?, do: "Verifying…", else: "Linking…")}
                >
                  {if(identity.linked?, do: "Verify", else: "Link")}
                </.button>
                <div :if={identity.user_verified?} class="space-y-1 sm:text-right">
                  <.button
                    id={"remove-oidc-#{identity.provider_id}"}
                    type="button"
                    variant={:secondary}
                    tone={:rose}
                    size={:sm}
                    disabled={not identity.removable?}
                    aria-describedby={
                      not identity.removable? && "remove-oidc-reason-#{identity.provider_id}"
                    }
                    phx-click="start_oidc_unlink"
                    phx-value-identity_id={identity.identity_id}
                    phx-disable-with="Opening…"
                  >
                    Remove
                  </.button>
                  <p
                    :if={not identity.removable?}
                    id={"remove-oidc-reason-#{identity.provider_id}"}
                    class="max-w-xs text-xs text-zinc-400"
                  >
                    Link another enabled sign-in method before removing this one.
                  </p>
                </div>
              </div>
            </li>
          </ul>

          <.oidc_step_dialog
            :if={@oidc_step}
            id="profile-oidc-step"
            form={@oidc_step_form}
            step={@oidc_step}
            purpose={@oidc_step.purpose}
            email={@current_user.email}
            error={@oidc_step_error}
            typed={@typed}
            handoff={@oidc_handoff}
            trigger_submit={@oidc_trigger_submit}
            action={~p"/app/#{@current_account}/settings/sso/identity/link"}
          />
        </.section_with_note>

        <.section_with_note id="multi-factor-authentication">
          <:header>
            <.section_header title="Multi-factor authentication">
              <:subtitle>Use an authenticator app for an extra check when you sign in.</:subtitle>
            </.section_header>
          </:header>
          <:note :if={not @mfa_facts.enabled? and @mfa_enrollment_step == :idle}>
            We recommend enabling MFA to help protect your profile.
          </:note>

          <%= cond do %>
            <% @mfa_recovery_codes -> %>
              <.mfa_setup_progress :if={@mfa_enrollment_step == :recovery} step={3} />
              <.secret_reveal
                id="mfa-recovery-codes"
                title="Save your recovery codes"
                codes={@mfa_recovery_codes}
                download_name="emisar-recovery-codes.txt"
              >
                Use a recovery code if you can't access your authenticator. Each code works once.
                Save these somewhere safe—you won't be able to view them again.
                <:actions>
                  <.recovery_code_acknowledgement
                    saved={@codes_saved?}
                    event="dismiss_recovery_codes"
                  />
                </:actions>
              </.secret_reveal>
            <% @mfa_facts.enabled? -> %>
              <p class="text-sm font-medium text-brand-300">Enabled</p>
              <% remaining = @mfa_facts.recovery_codes_remaining %>
              <div class="mt-2 space-y-1 text-sm">
                <p class="text-zinc-400">
                  <span class="tabular-nums">{remaining}</span>
                  recovery {if remaining == 1, do: "code", else: "codes"} remaining.
                </p>
                <p :if={remaining <= 2} class="text-amber-300">
                  Generate new codes before these run out.
                </p>
              </div>
              <div
                :if={@mfa_recovery_regeneration_step == :idle and @mfa_disable_step == :idle}
                class="mt-4 flex flex-wrap items-center gap-3"
              >
                <.button
                  id="regen-codes"
                  variant={:secondary}
                  size={:md}
                  type="button"
                  phx-click="start_regenerate_recovery_codes"
                >
                  Generate new recovery codes
                </.button>
                <.button
                  id="disable-mfa"
                  variant={:secondary}
                  tone={:rose}
                  size={:md}
                  phx-click="start_disable_mfa"
                >
                  Disable MFA
                </.button>
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
                    You'll stop using an authenticator code to sign in. You may need to set it
                    up again to access workspaces that require MFA.
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
                email={@current_user.email}
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
            <% true -> %>
              <div>
                <.chip tone={:amber}>Not enabled</.chip>
              </div>
              <.error :if={@mfa_start_error}>{@mfa_start_error}</.error>
              <.button
                variant={:primary}
                phx-click="start_mfa"
                phx-disable-with="Sending…"
                size={:md}
                class="mt-4"
              >
                Set up MFA
              </.button>
          <% end %>
        </.section_with_note>

        <.section_with_note id="sessions">
          <:header>
            <.section_header title="Active sessions">
              <:subtitle>
                Browsers and devices signed in to your profile.
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
            Don't recognize a session? Sign it out. That browser or device will need to sign in again.
            Signing out everywhere else keeps this session open.
          </:note>

          <%!-- No max-height: the scroll cap cropped the next row to a ~10px
               sliver that read as a rendering bug. Long lists paginate (10 a
               page) instead of scrolling, so "Sign out everywhere else" and the
               pager below carry the long-list affordance. space-y-4 spaces the
               pager off the list only when the pager renders (its :if drops the
               node on a single page, leaving one child and no phantom gap). --%>
          <div class="space-y-4">
            <p :if={not @sessions_loaded?} role="status" class="text-sm text-zinc-400">
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
                  Started
                  <.local_time
                    id={"session-started-#{session.id}"}
                    value={session.inserted_at}
                    mode={:relative}
                  /> · <span class="font-mono">{session.ip_address || "—"}</span>
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
