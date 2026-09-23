defmodule Emisar.Auth.CurrentSubjectTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, ApiKeys, Audit, Auth, Fixtures, Repo, RequestContext, Runners}
  alias Emisar.Auth.Subject

  @view Runners.Authorizer.view_runners_permission()
  @manage Runners.Authorizer.manage_runners_permission()
  @audit Audit.Authorizer.view_audit_permission()
  @billing_audit Audit.Authorizer.view_billing_audit_permission()

  describe "fetch_current_subject/2 for a human" do
    test "resolves live browser authority once for a protected read" do
      membership = Fixtures.Memberships.create_membership(role: "operator")
      subject = Fixtures.Subjects.membership_subject(membership)
      observe_queries()

      assert {:ok, _current} = Auth.fetch_current_subject(@view, subject)
      assert [_query] = queries()
    end

    test "an active member needs no runner or pack grants to keep read authority" do
      membership = Fixtures.Memberships.create_membership(role: "operator")
      subject = Fixtures.Subjects.membership_subject(membership)
      Fixtures.Memberships.force_runner_access(membership, Accounts.RunnerAccess.none())

      assert {:ok, current} = Auth.fetch_current_subject(@view, subject)
      assert current.permissions == subject.permissions
      assert current.membership_id == membership.id
      assert current.account.id == membership.account_id
      assert current.actor.id == membership.user_id
    end

    test "demotion removes an old permission while retaining the current role's reads" do
      membership = Fixtures.Memberships.create_membership(role: "admin")
      subject = Fixtures.Subjects.membership_subject(membership)
      Fixtures.Memberships.force_role(membership, "viewer")

      assert Auth.fetch_current_subject(@manage, subject) == {:error, :unauthorized}
      assert {:ok, current} = Auth.fetch_current_subject(@view, subject)
      assert current.role == :viewer
      assert current.permissions == Auth.Permissions.for_role(:viewer)
    end

    test "a billing demotion returns the narrowed audit subject, not the old full trail" do
      membership = Fixtures.Memberships.create_membership(role: "owner")
      subject = Fixtures.Subjects.membership_subject(membership)
      Fixtures.Memberships.force_role(membership, "billing_manager")

      assert {:ok, current} =
               Auth.fetch_current_subject({:one_of, [@audit, @billing_audit]}, subject)

      assert current.role == :billing_manager
      assert Audit.subject_sees_billing_audit_only?(current)
      refute Audit.subject_can_export_audit?(current)
      assert Auth.fetch_current_subject(@view, subject) == {:error, :unauthorized}
    end

    test "refresh never restores an intentionally attenuated permission" do
      membership = Fixtures.Memberships.create_membership(role: "admin")
      subject = Fixtures.Subjects.membership_subject(membership)
      subject = %{subject | permissions: MapSet.new([@view])}

      assert {:ok, current} = Auth.fetch_current_subject(@view, subject)
      assert current.role == :admin
      assert current.permissions == MapSet.new([@view])
    end

    test "a later promotion cannot enlarge the original permission snapshot" do
      membership = Fixtures.Memberships.create_membership(role: "viewer")
      subject = Fixtures.Subjects.membership_subject(membership)
      Fixtures.Memberships.force_role(membership, "admin")

      assert {:ok, current} = Auth.fetch_current_subject(@view, subject)
      assert current.role == :admin
      assert current.permissions == subject.permissions
      assert Auth.fetch_current_subject(@manage, subject) == {:error, :unauthorized}
    end

    test "directory authorization pending uses the existing effective Viewer role" do
      membership = Fixtures.Memberships.create_membership(role: "admin")
      subject = Fixtures.Subjects.membership_subject(membership)
      Fixtures.Memberships.mark_directory_authorization_pending(membership, 1)

      assert {:ok, current} = Auth.fetch_current_subject(@view, subject)
      assert current.role == :viewer
      assert Auth.fetch_current_subject(@manage, subject) == {:error, :unauthorized}
    end

    test "refresh keeps request and destination SSO proof while reloading the actor" do
      membership = Fixtures.Memberships.create_membership(role: "admin")
      original = Fixtures.Subjects.membership_subject(membership)
      Fixtures.Accounts.maybe_seed_plan(original.account, "team")

      provider =
        Fixtures.SSO.create_identity_provider(%{
          account_id: original.account.id,
          name: "Okta",
          satisfies_mfa: true
        })

      identity_id =
        Fixtures.SSO.create_user_identity(%{
          account_id: original.account.id,
          provider_id: provider.id,
          user_id: original.actor.id
        }).id

      context = RequestContext.new(request_id: "current-subject", ip_address: "127.0.0.1")

      subject =
        Fixtures.Subjects.subject_for(original.actor, original.account,
          context: context,
          auth_method: :sso,
          user_identity_id: identity_id
        )

      actor = Fixtures.Users.set_mfa_state(original.actor, mfa_enabled_at: DateTime.utc_now())

      assert {:ok, current} = Auth.fetch_current_subject(@view, subject)
      assert current.actor.mfa_enabled_at == actor.mfa_enabled_at
      assert current.context == context
      assert current.auth_method == :sso
      assert current.mfa == true
      assert current.mfa_enrollment_verified_at == nil
      assert current.user_identity_id == identity_id
      assert current.session_token_id == subject.session_token_id
      assert current.member_grant_id == subject.member_grant_id
    end

    test "revoked grant denies held context reads and cannot be replaced by another bearer" do
      {owner, account, owner_subject} = Fixtures.Subjects.owner_subject()
      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
      held = Fixtures.Subjects.membership_subject(member)

      assert {:ok, _rows, _page} = Runners.list_runners_for_account(held)
      assert :ok = Accounts.end_all_sessions_for(member, owner_subject)
      assert Runners.list_runners_for_account(held) == {:error, :unauthorized}
      assert Auth.fetch_current_subject(@view, held) == {:error, :unauthorized}
      assert Auth.ensure_personal_session(held) == :ok

      replacement = Fixtures.Subjects.subject_for(held.actor, account)
      assert {:ok, _current} = Auth.fetch_current_subject(@view, replacement)
      assert Auth.fetch_current_subject(@view, held) == {:error, :unauthorized}

      for altered <- [
            %{held | session_token_id: replacement.session_token_id},
            %{held | member_grant_id: replacement.member_grant_id},
            %{replacement | actor: owner},
            %{replacement | session_token_id: nil},
            %{replacement | member_grant_id: nil}
          ] do
        assert Auth.fetch_current_subject(@view, altered) == {:error, :unauthorized}
      end
    end

    test "one_of cannot join a cached permission to a different permission in the current role" do
      member = Fixtures.Memberships.create_membership(role: "owner")
      held = Fixtures.Subjects.membership_subject(member)
      held = %{held | permissions: MapSet.new([@audit])}
      Fixtures.Memberships.force_role(member, "billing_manager")

      assert Auth.Authorizer.ensure_has_permissions(held, {:one_of, [@audit, @billing_audit]}) ==
               {:error, :unauthorized}
    end

    test "current security requirements deny held reads and writes but keep accurate step-up diagnosis" do
      for {setting, reason} <- [require_mfa: :mfa_required, require_sso: :sso_required] do
        {_user, account, held} = Fixtures.Subjects.owner_subject(%{plan: "team"})
        Fixtures.SSO.create_identity_provider(account_id: account.id)
        updated = Fixtures.Accounts.set_account_settings(account, %{setting => true})

        assert Accounts.ensure_account_compliant(account, held) == {:error, reason}
        assert Runners.list_runners_for_account(held) == {:error, :unauthorized}

        assert Accounts.update_account(updated, %{name: "Denied"}, held) ==
                 {:error, :unauthorized}

        assert Auth.ensure_personal_session(held) == :ok

        assert {:ok, _member} =
                 Accounts.fetch_membership_by_account_id_or_slug(account.id, held)
      end
    end

    test "suspended and deleted memberships refuse held subjects" do
      suspended = Fixtures.Memberships.create_membership(role: "admin")
      suspended_subject = Fixtures.Subjects.membership_subject(suspended)
      Fixtures.Memberships.suspend_membership(suspended)
      deleted = Fixtures.Memberships.create_membership(role: "admin")
      deleted_subject = Fixtures.Subjects.membership_subject(deleted)
      Fixtures.Memberships.mark_membership_as_deleted(deleted)

      assert Auth.fetch_current_subject(@view, suspended_subject) == {:error, :unauthorized}
      assert Auth.fetch_current_subject(@view, deleted_subject) == {:error, :unauthorized}
    end

    test "a pending invitation cannot authorize a stale permission-bearing subject" do
      membership =
        Fixtures.Memberships.create_membership(
          role: "admin",
          invitation_token_digest: "pending-current-subject"
        )

      subject = Fixtures.Subjects.membership_subject(membership)
      subject = %{subject | role: :admin, permissions: Auth.Permissions.for_role(:admin)}

      assert Auth.fetch_current_subject(@view, subject) == {:error, :unauthorized}
    end

    test "disabled or deleted accounts and deleted users refuse held subjects" do
      for state <- [:disabled_account, :deleted_account, :deleted_user] do
        membership = Fixtures.Memberships.create_membership(role: "admin")
        subject = Fixtures.Subjects.membership_subject(membership)

        case state do
          :disabled_account -> Fixtures.Accounts.disable_account(subject.account)
          :deleted_account -> Fixtures.Accounts.mark_account_as_deleted(subject.account)
          :deleted_user -> Fixtures.Users.mark_user_as_deleted(subject.actor)
        end

        assert Auth.fetch_current_subject(@view, subject) == {:error, :unauthorized}
      end
    end

    test "account, user, membership, bearer and grant cannot be swapped independently" do
      membership = Fixtures.Memberships.create_membership(role: "admin")
      subject = Fixtures.Subjects.membership_subject(membership)
      foreign_membership = Fixtures.Memberships.create_membership(role: "admin")
      foreign = Fixtures.Subjects.membership_subject(foreign_membership)

      for mismatched <- [
            %{subject | account: foreign.account},
            %{subject | actor: foreign.actor},
            %{subject | membership_id: foreign.membership_id},
            %{subject | session_token_id: foreign.session_token_id},
            %{subject | member_grant_id: foreign.member_grant_id}
          ] do
        assert Auth.fetch_current_subject(@view, mismatched) == {:error, :unauthorized}
      end
    end

    test "a replacement membership cannot revive the old subject" do
      membership = Fixtures.Memberships.create_membership(role: "admin")
      subject = Fixtures.Subjects.membership_subject(membership)
      Fixtures.Memberships.mark_membership_as_deleted(membership)

      Fixtures.Memberships.create_membership(
        account_id: membership.account_id,
        user_id: membership.user_id,
        role: "admin"
      )

      assert Auth.fetch_current_subject(@view, subject) == {:error, :unauthorized}
    end
  end

  describe "fetch_api_key_membership/1" do
    test "revoked, expired, deleted and unbound keys refuse a held subject" do
      for state <- [:revoked, :expired, :deleted, :unbound] do
        account = Fixtures.Accounts.create_account()
        {_raw, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)
        subject = Subject.for_api_key(key, account)
        assert {:ok, member} = Accounts.fetch_api_key_membership(key)
        assert member.id == key.created_by_membership_id

        case state do
          :revoked -> Fixtures.ApiKeys.mark_revoked(key)
          :expired -> Fixtures.ApiKeys.backdate_api_key_expiry(key)
          :deleted -> Fixtures.ApiKeys.mark_deleted(key)
          :unbound -> Fixtures.ApiKeys.force_membership_unbound(key)
        end

        assert Accounts.fetch_api_key_membership(key) == {:error, :not_found}
        assert Auth.fetch_current_subject(@view, subject) == {:error, :unauthorized}
      end
    end

    test "the key's exact account and Member cannot be replaced independently" do
      {_raw, key} = Fixtures.ApiKeys.create_api_key()
      foreign = Fixtures.Memberships.create_membership()
      assert {:ok, member} = Accounts.fetch_api_key_membership(key)
      assert member.id == key.created_by_membership_id

      for changed <- [
            %{key | account_id: foreign.account_id},
            %{key | created_by_membership_id: foreign.id},
            %{key | account_id: foreign.account_id, created_by_membership_id: foreign.id}
          ] do
        assert Accounts.fetch_api_key_membership(changed) == {:error, :not_found}
      end
    end
  end

  describe "fetch_current_subject/2 for an API key" do
    test "an owner's key retains only fixed API permissions and its request context" do
      membership = Fixtures.Memberships.create_membership(role: "owner")
      owner = Fixtures.Subjects.membership_subject(membership)

      {_raw, key} =
        Fixtures.ApiKeys.create_api_key(
          account_id: owner.account.id,
          created_by_id: owner.actor.id
        )

      context =
        RequestContext.new(request_id: "api-subject", mcp_client_metadata: %{"team" => "ops"})

      subject = Subject.for_api_key(key, owner.account, context)
      subject = %{subject | role: :owner, permissions: owner.permissions}

      assert {:ok, current} = Auth.fetch_current_subject(@view, subject)
      assert current.role == :api_client

      assert current.permissions ==
               MapSet.intersection(owner.permissions, Auth.Permissions.for_role(:api_client))

      assert current.context == context
      assert current.auth_method == nil
      assert current.mfa == nil
      assert current.actor.id == key.id
      assert Auth.fetch_current_subject(@manage, subject) == {:error, :unauthorized}
    end

    test "current origin role must still be allowed to use the key kind" do
      membership = Fixtures.Memberships.create_membership(role: "operator")
      owner = Fixtures.Subjects.membership_subject(membership)

      {_raw, key} =
        Fixtures.ApiKeys.create_api_key(
          account_id: owner.account.id,
          created_by_id: owner.actor.id
        )

      subject = Subject.for_api_key(key, owner.account)
      Fixtures.Memberships.force_role(membership, "viewer")

      assert Auth.fetch_current_subject(@view, subject) == {:error, :unauthorized}
    end

    test "inactive origin identities or accounts cannot retain a key" do
      for state <- [
            :directory_pending,
            :suspended_member,
            :deleted_member,
            :deleted_user,
            :disabled_account,
            :deleted_account
          ] do
        membership = Fixtures.Memberships.create_membership(role: "admin")
        owner = Fixtures.Subjects.membership_subject(membership)

        {_raw, key} =
          Fixtures.ApiKeys.create_api_key(
            account_id: owner.account.id,
            created_by_id: owner.actor.id
          )

        subject = Subject.for_api_key(key, owner.account)

        case state do
          :directory_pending ->
            Fixtures.Memberships.mark_directory_authorization_pending(membership, 1)

          :suspended_member ->
            Fixtures.Memberships.suspend_membership(membership)

          :deleted_member ->
            Fixtures.Memberships.mark_membership_as_deleted(membership)

          :deleted_user ->
            Fixtures.Users.mark_user_as_deleted(owner.actor)

          :disabled_account ->
            Fixtures.Accounts.disable_account(owner.account)

          :deleted_account ->
            Fixtures.Accounts.mark_account_as_deleted(owner.account)
        end

        assert ApiKeys.peek_api_key_by_id(key.id) == nil
        assert Auth.fetch_current_subject(@view, subject) == {:error, :unauthorized}
      end
    end

    test "a no-action key refreshes mutable facts without restoring attenuated permissions" do
      membership = Fixtures.Memberships.create_membership(role: "operator")
      owner = Fixtures.Subjects.membership_subject(membership)

      {_raw, key} =
        Fixtures.ApiKeys.create_api_key(
          account_id: owner.account.id,
          created_by_id: owner.actor.id
        )

      subject = Subject.for_api_key(key, owner.account)
      subject = %{subject | permissions: MapSet.new([@view])}
      Fixtures.Memberships.force_runner_access(membership, Accounts.RunnerAccess.none())
      used_key = Fixtures.ApiKeys.mark_used(key)

      assert {:ok, current} = Auth.fetch_current_subject(@view, subject)
      assert current.role == :api_client
      assert current.permissions == MapSet.new([@view])
      assert current.actor.last_used_at == used_key.last_used_at
      assert current.actor.credential_lineage_id == key.credential_lineage_id
    end

    test "a key cannot be rebound to another account, member, kind or recovery lineage" do
      membership = Fixtures.Memberships.create_membership(role: "admin")
      owner = Fixtures.Subjects.membership_subject(membership)

      {_raw, key} =
        Fixtures.ApiKeys.create_api_key(
          account_id: owner.account.id,
          created_by_id: owner.actor.id
        )

      subject = Subject.for_api_key(key, owner.account)
      foreign_membership = Fixtures.Memberships.create_membership(role: "admin")
      foreign = Fixtures.Subjects.membership_subject(foreign_membership)

      for mismatched <- [
            %{subject | account: foreign.account},
            %{subject | membership_id: foreign.membership_id},
            %{subject | actor: %{key | created_by_membership_id: foreign.membership_id}},
            %{subject | actor: %{key | kind: :audit_export}},
            %{subject | actor: %{key | credential_lineage_id: Repo.generate_id()}}
          ] do
        assert Auth.fetch_current_subject(@view, mismatched) == {:error, :unauthorized}
      end
    end
  end

  describe "early denial" do
    test "single, all-required and one-of snapshot permission denials execute no SQL" do
      membership = Fixtures.Memberships.create_membership(role: "admin")
      subject = Fixtures.Subjects.membership_subject(membership)
      subject = %{subject | permissions: MapSet.new([@view])}
      observe_queries()

      for permissions <- [@manage, [@view, @manage], {:one_of, [@manage, @audit]}] do
        assert Auth.fetch_current_subject(permissions, subject) == {:error, :unauthorized}
      end

      assert queries() == []
    end

    test "malformed, actorless and accountless subjects fail without SQL" do
      membership = Fixtures.Memberships.create_membership(role: "admin")
      subject = Fixtures.Subjects.membership_subject(membership)

      subjects = [
        %{subject | membership_id: nil},
        %{subject | membership_id: "not-a-uuid"},
        %{subject | account: %{subject.account | id: subject.account.slug}},
        %{subject | actor: %{subject.actor | id: "not-a-uuid"}},
        %{subject | actor: nil},
        %{subject | account: nil}
      ]

      observe_queries()

      for invalid <- subjects do
        assert Auth.fetch_current_subject(@view, invalid) == {:error, :unauthorized}
      end

      assert queries() == []
    end
  end

  defp observe_queries do
    handler = "current-subject-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach(handler, [:emisar, :repo, :query], &__MODULE__.query_event/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  def query_event(_event, _measurements, metadata, owner) do
    if self() == owner, do: send(owner, {:subject_query, metadata.query})
  end

  defp queries(acc \\ []) do
    receive do
      {:subject_query, query} -> queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
