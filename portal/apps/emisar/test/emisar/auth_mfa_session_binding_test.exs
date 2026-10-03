defmodule Emisar.AuthMfaSessionBindingTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Auth, Crypto, Fixtures, Repo, RequestContext}

  defp browser_session(member) do
    raw = Fixtures.Auth.create_session_token!(member, :magic_link, nil)
    {:ok, token} = Auth.fetch_session_by_token(raw, member.account_id)
    {raw, token, Fixtures.Subjects.subject_for(member, session: raw)}
  end

  describe "fetch_current_session/1 — browser proof" do
    for state <- [:revoked, :expired, :missing, :foreign, :wrong_context] do
      @state state
      test "#{state} browser proof is denied before facts, mail, attempts or factor consumption" do
        Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
        {owner, _account, _owner} = Fixtures.Subjects.owner_subject()
        {raw, token, subject} = browser_session(owner)
        recovery_code = "disposable-recovery-proof"

        enrolled =
          Fixtures.Memberships.set_mfa_state(owner,
            mfa_secret: Auth.generate_mfa_secret(),
            mfa_enabled_at: DateTime.utc_now(),
            mfa_recovery_codes: [Crypto.hash(recovery_code)]
          )

        invalid =
          case @state do
            :revoked ->
              :ok = Auth.revoke_session_tokens([raw], :dead_entry, %RequestContext{})
              subject

            :expired ->
              Fixtures.Auth.backdate_session_token!(
                raw,
                DateTime.add(DateTime.utc_now(), -61, :day)
              )

              subject

            :missing ->
              %{subject | session_token_id: nil}

            :foreign ->
              # Another Member holding this session's id: the actor must be the
              # session's own Member.
              %{subject | actor: Fixtures.Memberships.create_membership()}

            :wrong_context ->
              code = Fixtures.Auth.create_aged_token!(owner, "magic_link", DateTime.utc_now())
              %{subject | session_token_id: code.id}
          end

        assert Auth.fetch_current_session(invalid) == {:error, :unauthorized}
        assert Auth.mfa_facts(invalid) == {:error, :unauthorized}
        assert Auth.issue_mfa_enrollment_code(invalid) == {:error, :unauthorized}
        assert Auth.verify_mfa_enrollment_code("ABCDEF", invalid) == {:error, :unauthorized}

        assert Auth.verify_current_session_mfa_challenge({:recovery_code, recovery_code}, invalid) ==
                 {:error, :unauthorized}

        assert Auth.disable_mfa(recovery_code, invalid) == {:error, :unauthorized}

        assert Auth.regenerate_mfa_recovery_codes(recovery_code, invalid) ==
                 {:error, :unauthorized}

        assert Repo.reload!(enrolled) == enrolled
        assert Repo.aggregate(Auth.SecurityAttemptWindow, :count) == 0
        refute_received {:email, _}
        refute Repo.exists?(Auth.UserToken.Query.by_context("mfa_enrollment"))
        assert is_nil(token.mfa_enrollment_verified_at)
      end
    end

    test "a revoked browser cannot spend or consume an outstanding enrollment code" do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      {owner, _account, _owner} = Fixtures.Subjects.owner_subject()
      {raw, _token, subject} = browser_session(owner)
      assert Auth.issue_mfa_enrollment_code(subject) == {:ok, :sent}
      assert_received {:email, email}
      code = Fixtures.Auth.code_from_email(email)
      pending = Auth.UserToken.Query.by_context("mfa_enrollment") |> Repo.one!()
      attempts = Repo.all(Auth.SecurityAttemptWindow)
      assert Auth.revoke_session_tokens([raw], :dead_entry, %RequestContext{}) == :ok

      assert Auth.verify_mfa_enrollment_code(code, subject) == {:error, :unauthorized}
      assert Repo.reload!(pending) == pending
      assert Repo.all(Auth.SecurityAttemptWindow) == attempts
    end

    test "facts come from the current Member, not a held actor snapshot" do
      {owner, _account, subject} = Fixtures.Subjects.owner_subject()

      current =
        Fixtures.Memberships.set_mfa_state(owner,
          mfa_enabled_at: DateTime.utc_now(),
          mfa_recovery_codes: []
        )

      assert {:ok, session} = Auth.fetch_current_session(subject)
      assert session.id == subject.session_token_id
      assert session.membership.id == current.id
      assert session.membership.mfa_enabled_at == current.mfa_enabled_at
      assert {:ok, facts} = Auth.mfa_facts(subject)
      assert facts.enabled?
      assert facts.recovery_codes_remaining == 0
    end
  end

  describe "exact-browser MFA completion" do
    test "enrollment cannot stamp another live browser belonging to the same Member" do
      {owner, _account, _owner} = Fixtures.Subjects.owner_subject()
      {_raw_a, _token_a, subject_a} = browser_session(owner)
      {raw_b, token_b, _subject_b} = browser_session(owner)
      token_b = Repo.reload!(token_b)
      proof = Fixtures.Memberships.mfa_enrollment_proof(subject_a)
      secret = Auth.generate_mfa_secret()

      assert Auth.enable_mfa(
               secret,
               Fixtures.Auth.totp_code(secret),
               proof,
               Crypto.hash(raw_b),
               subject_a
             ) == {:error, :session_not_found}

      assert is_nil(Repo.reload!(owner).mfa_enabled_at)
      assert Repo.reload!(token_b) == token_b
    end

    test "step-up cannot stamp another live browser belonging to the same Member" do
      {owner, _account, _owner} = Fixtures.Subjects.owner_subject()
      {_raw_a, _token_a, subject_a} = browser_session(owner)
      {raw_b, token_b, _subject_b} = browser_session(owner)
      token_b = Repo.reload!(token_b)
      recovery_code = "disposable-step-up-proof"

      Fixtures.Memberships.set_mfa_state(owner,
        mfa_enabled_at: DateTime.utc_now(),
        mfa_recovery_codes: [Crypto.hash(recovery_code)]
      )

      assert {:ok, proof} =
               Auth.verify_current_session_mfa_challenge(
                 {:recovery_code, recovery_code},
                 subject_a
               )

      assert Auth.complete_current_session_mfa(proof, Crypto.hash(raw_b), subject_a) ==
               {:error, :session_not_found}

      assert Repo.reload!(token_b) == token_b
    end
  end
end
