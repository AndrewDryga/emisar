defmodule EmisarWeb.ProfileLive do
  use EmisarWeb, :live_view
  alias Emisar.{Auth, Users}
  alias EmisarWeb.{LiveForm, LiveTable, UserAgent}
  alias Phoenix.LiveView.JS

  # Both step-ups on this page — the email-change authenticator branch and
  # disabling 2FA — spend the same per-user MFA attempt window, so they report
  # its exhaustion in the same words.
  @mfa_rate_limit_error "Too many attempts. Wait a few minutes, then try again."
  @email_issue_rate_limit_error "Too many code requests. Wait up to 15 minutes, then try again."
  @mfa_enrollment_email_unavailable_error "Your identity provider did not supply an email address. Ask your administrator to update it, then sign in again."
  @mfa_enrollment_email_suppressed_error "Emisar cannot deliver mail to your current address. Contact support to restore email delivery before setting up 2FA."
  @mfa_enrollment_email_delivery_error "We could not deliver the verification code. Try again. If it keeps failing, contact support."

  def mount(_params, session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, "Profile")
     |> assign(:mfa_recovery_codes, nil)
     |> assign(:mfa_recovery_regeneration_step, :idle)
     |> assign(:mfa_recovery_regeneration_error, nil)
     |> assign(:mfa_disable_step, :idle)
     |> assign(:mfa_disable_error, nil)
     |> assign(:current_session_token, session["user_token"])
     |> assign(:session_count, 0)
     |> assign(:session_page_count, 0)
     |> assign(:metadata, %Emisar.Repo.Paginator.Metadata{count: 0, limit: 0})
     |> assign(:filter_params, %{})
     |> assign_mfa_facts(user)
     |> assign_profile_form(user)
     |> assign_email_form(user)
     |> reset_mfa_enrollment()
     |> assign_mfa_recovery_regeneration_form()
     |> assign_mfa_disable_form()
     |> reset_email_step()
     |> stream(:sessions, [])}
  end

  def handle_params(params, _uri, socket), do: {:noreply, maybe_load_sessions(socket, params)}

  # IL-18: the session list is the only DB read on this page — skip it on the
  # pre-connect static render so mount + handle_params do no query work; the
  # connected params load fills it in, and each prev/next patch re-runs it.
  defp maybe_load_sessions(socket, params) do
    if connected?(socket) do
      load_sessions(socket, params)
    else
      assign(socket, :filter_params, params)
    end
  end

  # 15 a page: a heavy automation account can hold ~100 sessions, and an
  # ungrouped wall of near-identical rows buries the one unfamiliar device an
  # operator is scanning for. Cursor-paginated (UserToken.Query.cursor_fields).
  defp load_sessions(socket, params) do
    opts = LiveTable.params_to_opts(params)
    list_opts = Keyword.put(opts, :page, Keyword.put(opts[:page], :limit, 15))

    presented_token = socket.assigns.current_session_token

    case Auth.list_sessions_for_user(presented_token, socket.assigns.current_subject, list_opts) do
      {:ok, sessions, metadata} ->
        presented = Enum.map(sessions, &present_session/1)

        socket
        |> assign(:session_count, metadata.count || 0)
        |> assign(:session_page_count, length(presented))
        |> assign(:metadata, metadata)
        |> assign(:filter_params, params)
        |> stream(:sessions, presented, reset: true)

      # A bad cursor from a hand-edited URL — retry once, clean, on page 1.
      {:error, _} when map_size(params) > 0 ->
        load_sessions(socket, %{})

      {:error, _} ->
        socket
        |> assign(:session_count, 0)
        |> assign(:session_page_count, 0)
        |> assign(:filter_params, params)
        |> stream(:sessions, [], reset: true)
    end
  end

  # Reload the page the operator is on after a revoke, so a single sign-out
  # doesn't bounce them back to page 1 (their cursor rides on filter_params).
  defp reload_sessions(socket), do: load_sessions(socket, socket.assigns.filter_params)

  defp present_session(%Auth.SessionFacts{} = session) do
    %{
      id: session.id,
      device_label: session_device_label(session.user_agent),
      icon: session_device_icon(session.user_agent),
      current?: session.current?,
      ip_address: session_ip(session.ip_address),
      inserted_at: session.inserted_at
    }
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
         |> put_flash(:info, "Profile updated.")
         |> assign(:current_user, updated)
         |> assign_profile_form(updated)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :profile_form, to_form(changeset, as: "profile"))}

      {:error, _reason} ->
        changeset = Users.change_user(socket.assigns.current_user, params)

        {:noreply,
         socket
         |> assign(:profile_form, to_form(changeset, as: "profile"))
         |> put_flash(:error, "Couldn't update your profile. Try again.")}
    end
  end

  def handle_event("validate_email", %{"email" => params} = event, socket) do
    changeset =
      socket.assigns.current_user
      |> Users.change_user(%{"email" => params["email"] || ""})
      |> LiveForm.on_change(event)

    {:noreply, assign(socket, :email_form, to_form(changeset, as: "email"))}
  end

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
        {:noreply, put_flash(socket, :info, "That's already your email.")}

      true ->
        {:noreply, start_email_step_up(socket, user, new_email)}
    end
  end

  def handle_event("confirm_email_change", %{"email_step" => %{"code" => code}}, socket) do
    %{email_step: step, pending_new_email: new_email, current_subject: subject} = socket.assigns

    # Sequencing guard is the web's own state; the step-up factor decision, the
    # verify, and the commit are all `Auth.confirm_email_change`'s call — the
    # domain re-derives the factor from the fresh row and gates the write.
    if step in [:totp, :code] and is_binary(new_email) do
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
    if step == :code and is_binary(new_email) do
      case Auth.issue_email_change_code(new_email, socket.assigns.current_subject) do
        :ok ->
          {:noreply,
           socket
           |> assign(:email_step_error, nil)
           |> put_flash(:info, "We sent a new code to #{socket.assigns.current_user.email}.")}

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, "Couldn't send a new code. Try again.")}

        {:error, :rate_limited} ->
          {:noreply, assign(socket, :email_step_error, @email_issue_rate_limit_error)}
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

  def handle_event("revoke_session", %{"id" => id}, socket) do
    case Auth.revoke_session(id, socket.assigns.current_subject) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Session revoked.") |> reload_sessions()}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Session no longer exists.")}
    end
  end

  def handle_event("revoke_other_sessions", _params, socket) do
    keep = socket.assigns.current_session_token

    revoked_count =
      Auth.revoke_and_disconnect_other_sessions!(keep, socket.assigns.current_subject)

    msg =
      case revoked_count do
        0 -> "No other sessions to revoke."
        1 -> "1 other session signed out."
        revoked_count -> "#{revoked_count} other sessions signed out."
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
         |> assign(:mfa_enrollment_email_error, nil)
         |> put_flash(:info, "We emailed a verification code to your current address.")}

      {:ok, :suppressed} ->
        {:noreply, put_flash(socket, :error, @mfa_enrollment_email_suppressed_error)}

      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, @email_issue_rate_limit_error)}

      {:error, :email_unavailable} ->
        {:noreply, put_flash(socket, :error, @mfa_enrollment_email_unavailable_error)}

      {:error, :mfa_already_enabled} ->
        {:noreply, refresh_after_mfa_enabled(socket)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, @mfa_enrollment_email_delivery_error)}
    end
  end

  def handle_event(
        "verify_mfa_enrollment_email",
        %{"mfa_enrollment" => %{"code" => code}},
        socket
      ) do
    if socket.assigns.mfa_enrollment_step == :email do
      case Auth.verify_mfa_enrollment_code(
             String.trim(code || ""),
             socket.assigns.current_subject
           ) do
        {:ok, proof} ->
          {:noreply, prepare_mfa_authenticator(socket, proof)}

        {:error, :invalid} ->
          {:noreply,
           assign(
             socket,
             :mfa_enrollment_email_error,
             "That code is wrong or expired. Try again."
           )}

        {:error, :rate_limited} ->
          {:noreply, assign(socket, :mfa_enrollment_email_error, @mfa_rate_limit_error)}

        {:error, :email_unavailable} ->
          {:noreply,
           socket
           |> put_flash(:error, @mfa_enrollment_email_unavailable_error)
           |> reset_mfa_enrollment()}

        {:error, :mfa_already_enabled} ->
          {:noreply, refresh_after_mfa_enabled(socket)}

        {:error, _reason} ->
          {:noreply,
           assign(socket, :mfa_enrollment_email_error, "Could not verify that code. Try again.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Start the enable flow first.")}
    end
  end

  def handle_event("resend_mfa_enrollment_email", _params, socket) do
    if socket.assigns.mfa_enrollment_step == :email do
      case Auth.issue_mfa_enrollment_code(socket.assigns.current_subject) do
        {:ok, :sent} ->
          {:noreply,
           socket
           |> assign(:mfa_enrollment_email_error, nil)
           |> put_flash(:info, "We sent a new verification code.")}

        {:ok, :suppressed} ->
          {:noreply,
           assign(socket, :mfa_enrollment_email_error, @mfa_enrollment_email_suppressed_error)}

        {:error, :rate_limited} ->
          {:noreply, assign(socket, :mfa_enrollment_email_error, @email_issue_rate_limit_error)}

        {:error, :mfa_already_enabled} ->
          {:noreply, refresh_after_mfa_enabled(socket)}

        {:error, _reason} ->
          {:noreply,
           assign(socket, :mfa_enrollment_email_error, @mfa_enrollment_email_delivery_error)}
      end
    else
      {:noreply, put_flash(socket, :error, "Start the enable flow first.")}
    end
  end

  def handle_event("cancel_mfa", _params, socket) do
    {:noreply, reset_mfa_enrollment(socket)}
  end

  def handle_event("confirm_mfa", %{"mfa" => %{"otp" => otp}}, socket) do
    secret = socket.assigns.mfa_secret

    if is_nil(secret) do
      {:noreply, put_flash(socket, :error, "Start the enable flow first.")}
    else
      case Auth.enable_mfa(
             secret,
             otp,
             socket.assigns.mfa_enrollment_proof,
             socket.assigns.current_subject
           ) do
        {:ok, updated, recovery_codes} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             "2FA enabled. Copy your recovery codes below — they'll only be shown once."
           )
           |> assign(:current_user, updated)
           |> assign_mfa_facts(updated)
           |> assign(:mfa_recovery_codes, recovery_codes)
           |> reset_mfa_enrollment()}

        {:error, :invalid_otp} ->
          {:noreply, assign(socket, :mfa_error, "Invalid code — try the next one.")}

        {:error, :mfa_enrollment_proof_stale} ->
          {:noreply,
           socket
           |> put_flash(:error, "Your account changed. Verify your current email again.")
           |> reset_mfa_enrollment()}

        {:error, :mfa_already_enabled} ->
          {:noreply, refresh_after_mfa_enabled(socket)}

        {:error, _changeset} ->
          {:noreply, assign(socket, :mfa_error, "Could not enable 2FA. Try again.")}
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
    {:noreply, assign(socket, :mfa_recovery_codes, nil)}
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
         |> put_flash(:info, "2FA disabled.")
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
         |> assign(:mfa_disable_error, @mfa_rate_limit_error)}

      {:error, :invalid_code} ->
        {:noreply,
         socket
         |> assign(:mfa_disable_step, :code)
         |> assign(:mfa_disable_error, "That code did not match. Try again.")}

      {:error, :replay} ->
        {:noreply,
         socket
         |> assign(:mfa_disable_step, :code)
         |> assign(:mfa_disable_error, "That authenticator code was already used. Try again.")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:mfa_disable_step, :code)
         |> assign(:mfa_disable_error, "Could not disable 2FA. Try again.")}
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
         |> reset_mfa_recovery_regeneration()}

      {:error, :rate_limited} ->
        {:noreply,
         socket
         |> assign(:mfa_recovery_regeneration_step, :code)
         |> assign(:mfa_recovery_regeneration_error, @mfa_rate_limit_error)}

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
         |> put_flash(:error, "Enable 2FA first.")
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

  # Email-change step-up state: :idle (the edit form), :totp (an MFA-on user
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
    case Auth.confirm_email_change(new_email, code, subject) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "Email updated.")
         |> assign(:current_user, updated)
         |> assign_email_form(updated)
         |> reset_email_step()}

      # Capped before the code was even checked — the step-up stays open so the
      # operator can retry once the window rolls over.
      {:error, :rate_limited} ->
        {:noreply, assign(socket, :email_step_error, @mfa_rate_limit_error)}

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
      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not change to that email — it may already be in use.")
         |> reset_email_step()}
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

      {:error, :rate_limited} ->
        socket
        |> put_flash(:error, @email_issue_rate_limit_error)
        |> reset_email_step()

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Couldn't start the email change. Try again.")
        |> reset_email_step()
    end
  end

  defp step_up_error(:totp), do: "That authenticator code didn't match. Try again."

  defp step_up_error(_),
    do: "That confirmation code is wrong or expired. Try again, or resend a new one."

  defp assign_mfa_form(socket) do
    assign(socket, :mfa_form, to_form(%{"otp" => ""}, as: "mfa"))
  end

  defp assign_mfa_enrollment_email_form(socket) do
    assign(socket, :mfa_enrollment_email_form, to_form(%{"code" => ""}, as: "mfa_enrollment"))
  end

  defp prepare_mfa_authenticator(socket, proof) do
    secret = Auth.generate_mfa_secret()
    uri = EmisarWeb.MfaQr.provisioning_uri(socket.assigns.current_user.email, secret)

    socket
    |> assign(:mfa_enrollment_step, :totp)
    |> assign(:mfa_enrollment_proof, proof)
    |> assign(:mfa_secret, secret)
    |> assign(:mfa_uri, uri)
    |> assign(:mfa_qr_svg, EmisarWeb.MfaQr.svg(uri))
    |> assign(:mfa_error, nil)
    |> assign_mfa_form()
  end

  defp reset_mfa_enrollment(socket) do
    socket
    |> assign(:mfa_enrollment_step, :idle)
    |> assign(:mfa_enrollment_proof, nil)
    |> assign(:mfa_enrollment_email_error, nil)
    |> assign(:mfa_secret, nil)
    |> assign(:mfa_uri, nil)
    |> assign(:mfa_qr_svg, nil)
    |> assign(:mfa_error, nil)
    |> assign_mfa_enrollment_email_form()
    |> assign_mfa_form()
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

  defp session_device_label(user_agent) when is_binary(user_agent),
    do: UserAgent.label(user_agent)

  defp session_device_label(_user_agent), do: "Unknown device"

  # No-op for the broadcasts the on_mount badge/fleet hooks forward (approvals,
  # pack trust, runner presence). The hooks own those nav cues; this page ignores them.
  def handle_info(_msg, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_subject={@current_subject}
      current_membership={@current_membership}
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
      fleet_all_offline?={@fleet_all_offline?}
      no_agents?={@no_agents?}
      onboarding_incomplete?={@onboarding_incomplete?}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:profile}
      width={:settings}
    >
      <:title>Profile</:title>

      <.page_intro>
        Your identity and sign-in security — the same across every workspace you belong to.
        <.doc_link href="/security">Security overview</.doc_link>
      </.page_intro>

      <%!-- CONTENT ON CANVAS: one naked section per concern (§8.1 — the
           fields, the enrollment block, and the reveal card are the only
           surfaces; a panel around a form was an island). --%>
      <div class="mt-4 max-w-2xl space-y-12">
        <section>
          <.section_header title="Display name">
            <:subtitle>How you appear to other members.</:subtitle>
          </.section_header>
          <.simple_form
            for={@profile_form}
            id="profile_form"
            phx-change="validate_profile"
            phx-submit="save_profile"
          >
            <%!-- No field label — the section title already says "Display name"
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
              <%!-- Emerald once edited, quiet outlined while clean — the Save
                   button IS the unsaved-changes signal (house pattern). --%>
              <.button
                variant={if @profile_form.source.changes == %{}, do: :secondary, else: :primary}
                phx-disable-with="Saving..."
              >
                Save
              </.button>
            </:actions>
          </.simple_form>
        </section>

        <section>
          <.section_header title="Email">
            <:subtitle>
              Used to sign in — every future sign-in link goes to it, so a change is
              confirmed with a second step.
            </:subtitle>
          </.section_header>
          <%= case @email_step do %>
            <% :idle -> %>
              <.simple_form
                for={@email_form}
                id="email_form"
                phx-change="validate_email"
                phx-submit="save_email"
              >
                <%!-- No field label — the panel title "Email" carries it (one
                     voice on a single-field panel); aria-label for a11y. --%>
                <.input
                  field={@email_form[:email]}
                  type="email"
                  aria-label="Email address"
                  autocomplete="email"
                  required
                />
                <:actions>
                  <.button
                    variant={if @email_form.source.changes == %{}, do: :secondary, else: :primary}
                    phx-disable-with="Checking..."
                  >
                    Update email
                  </.button>
                </:actions>
              </.simple_form>
            <% step -> %>
              <.simple_form
                for={@email_step_form}
                id="email_step_form"
                phx-submit="confirm_email_change"
              >
                <p class="text-sm text-zinc-300">
                  Confirm changing your email to <span class="font-medium text-zinc-100">{@pending_new_email}</span>.
                </p>
                <p :if={step == :code} class="text-xs text-zinc-400">
                  We emailed a 6-digit code to your current address ({@current_user.email}). Entering
                  it proves it's really you — an open session alone can't change your email.
                </p>
                <p :if={step == :totp} class="text-xs text-zinc-400">
                  Enter the code from your authenticator app — your second factor confirms the change.
                </p>
                <.code_input
                  id="email-step-code"
                  name="email_step[code]"
                  numeric
                  label={if step == :totp, do: "Authenticator code", else: "Confirmation code"}
                  error={@email_step_error}
                />
                <:actions>
                  <.button phx-disable-with="Confirming...">Confirm change</.button>
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
                    variant={:secondary}
                    size={:md}
                    type="button"
                    phx-click="cancel_email_change"
                  >
                    Cancel
                  </.button>
                </:actions>
              </.simple_form>
          <% end %>
        </section>

        <section>
          <%!-- No On/off badge: the sole action ("Set up 2FA" / "Disable 2FA")
               already states the current state unambiguously. --%>
          <.section_header title="Two-factor authentication">
            <:subtitle>
              Adds a TOTP code at sign-in, so a leaked sign-in link alone can't get in.
            </:subtitle>
          </.section_header>

          <%= cond do %>
            <% @mfa_recovery_codes -> %>
              <%!-- One-shot reveal — codes are only shown right after
                   enable / regenerate. The card forces an explicit
                   "I saved them" before the user can close. --%>
              <.secret_reveal
                id="mfa-recovery-codes"
                variant={:card}
                title="Save your recovery codes"
                codes={@mfa_recovery_codes}
                download_name="emisar-recovery-codes.txt"
              >
                Each code works once if you can't reach your authenticator. Store them in a
                password manager — we can't show them again.
                <:actions>
                  <.confirm_button
                    id="ack-recovery-codes"
                    title="Stored them somewhere safe?"
                    confirm_label="I've saved them"
                    variant={:secondary}
                    tone={:neutral}
                    size={:sm}
                    on_confirm={JS.push("dismiss_recovery_codes")}
                  >
                    <:body>Once this closes we can't show these recovery codes again.</:body>
                    I've saved them
                  </.confirm_button>
                </:actions>
              </.secret_reveal>
            <% @mfa_facts.enabled? -> %>
              <p class="text-sm text-zinc-300">
                You're protected by a second factor. Disabling means a leaked sign-in link is
                enough to sign in.
              </p>
              <%!-- Recovery codes burn down one per lost-device sign-in, but the
                   count was never surfaced — nudge to regenerate before they run
                   out and a lost authenticator becomes a lockout. --%>
              <% remaining = @mfa_facts.recovery_codes_remaining %>
              <p class={[
                "mt-3 text-xs",
                if(remaining <= 2, do: "font-medium text-amber-300", else: "text-zinc-400")
              ]}>
                {remaining} recovery {if remaining == 1, do: "code", else: "codes"} remaining.<span :if={
                  remaining <= 2
                }>
                  Regenerate for a fresh set before a lost authenticator locks you out.
                </span>
              </p>
              <div class="mt-4 flex flex-wrap items-center gap-3">
                <.button
                  id="regen-codes"
                  variant={:secondary}
                  size={:md}
                  type="button"
                  phx-click="start_regenerate_recovery_codes"
                >
                  Regenerate recovery codes
                </.button>
                <.confirm_button
                  id="disable-2fa"
                  title="Disable 2FA on your account?"
                  confirm_label="Disable 2FA"
                  variant={:secondary}
                  tone={:rose}
                  size={:md}
                  on_confirm={JS.push("start_disable_mfa")}
                >
                  <:body>A leaked sign-in link alone will then be enough to sign in.</:body>
                  Disable 2FA
                </.confirm_button>
              </div>
              <.simple_form
                :if={@mfa_recovery_regeneration_step == :code}
                for={@mfa_recovery_regeneration_form}
                id="mfa_recovery_regeneration_form"
                phx-submit="regenerate_recovery_codes"
                class="mt-5 max-w-md"
              >
                <p class="text-sm text-zinc-300">
                  Enter your authenticator code or one current recovery code. The old recovery
                  codes stop working only after this proof succeeds.
                </p>
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
                  <.button phx-disable-with="Regenerating...">Regenerate codes</.button>
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
                class="mt-5 max-w-md"
              >
                <p class="text-sm text-zinc-300">
                  Enter your authenticator code or one of your recovery codes to confirm.
                </p>
                <.input
                  field={@mfa_disable_form[:code]}
                  type="text"
                  label="Authenticator or recovery code"
                  autocomplete="one-time-code"
                  required
                />
                <.error :if={@mfa_disable_error}>{@mfa_disable_error}</.error>
                <:actions>
                  <.button phx-disable-with="Disabling...">Disable 2FA</.button>
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
              <.mfa_enrollment_email_verification
                email={@current_user.email}
                form={@mfa_enrollment_email_form}
                error={@mfa_enrollment_email_error}
              >
                <:actions>
                  <.button phx-disable-with="Verifying...">Verify email</.button>
                  <.button
                    variant={:ghost}
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
            <% @mfa_uri -> %>
              <.mfa_enrollment
                qr_svg={@mfa_qr_svg}
                uri={@mfa_uri}
                form={@mfa_form}
                variant={:split}
                error={@mfa_error}
              >
                <:instructions>
                  Scan with Google Authenticator, 1Password, Authy, or similar — then enter
                  the 6-digit code to confirm.
                </:instructions>
                <:actions>
                  <.button phx-disable-with="Verifying...">Confirm and enable</.button>
                  <.button variant={:ghost} type="button" phx-click="cancel_mfa">
                    Cancel
                  </.button>
                </:actions>
              </.mfa_enrollment>
            <% true -> %>
              <p class="text-sm text-zinc-300">
                Verify your current email, then scan a TOTP secret with your authenticator app and
                confirm its 6-digit code.
              </p>
              <%!-- Secondary like every profile island action — this page has
                   no single primary (ONE emerald fill per viewport). --%>
              <.button variant={:secondary} phx-click="start_mfa" size={:md} class="mt-4">
                Set up 2FA
              </.button>
          <% end %>
        </section>

        <section>
          <.section_header title="Active sessions">
            <:subtitle>
              Each row is one signed-in browser or device. Sign out of any you don't
              recognize — your current device stays signed in.
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

          <%!-- No max-height: the scroll cap cropped the next row to a ~10px
               sliver that read as a rendering bug. Long lists paginate (15 a
               page) instead of scrolling, so "Sign out everywhere else" and the
               pager below carry the long-list affordance. space-y-4 spaces the
               pager off the list only when the pager renders (its :if drops the
               node on a single page, leaving one child and no phantom gap). --%>
          <div class="space-y-4">
            <ul
              id="active-sessions"
              phx-update="stream"
              class="divide-y divide-zinc-800/70 text-sm"
            >
              <.list_row
                :for={{dom_id, session} <- @streams.sessions}
                id={dom_id}
                icon={session.icon}
                class={session.current? && "bg-brand-500/[0.04]"}
              >
                <:title>
                  <span class="truncate font-medium text-zinc-100">
                    {session.device_label}
                  </span>
                </:title>
                <:chips>
                  <.chip :if={session.current?} tone={:neutral}>
                    this device
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
        </section>
      </div>
    </.dashboard_shell>
    """
  end

  # Picks an icon for the session row that hints at the device class —
  # makes the row visually scannable instead of "wall of identical text".
  defp session_device_icon(user_agent) when is_binary(user_agent), do: UserAgent.icon(user_agent)
  defp session_device_icon(_user_agent), do: "hero-globe-alt"
end
