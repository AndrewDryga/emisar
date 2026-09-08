defmodule Emisar.AccountsAuditReceiptsTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Audit, Crypto, Fixtures}

  describe "account update receipts" do
    test "records the locked before value when the caller's account is stale" do
      account = Fixtures.Accounts.create_account(name: "Original")
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)

      assert {:ok, _} = Accounts.update_account(account, %{name: "Intermediate"}, subject)
      assert {:ok, _} = Accounts.update_account(account, %{name: "Final"}, subject)

      payloads = Enum.map(events("account.updated"), & &1.payload)

      assert length(payloads) == 2

      assert %{
               "changes" => %{"name" => %{"before" => "Original", "after" => "Intermediate"}}
             } in payloads

      assert %{
               "changes" => %{"name" => %{"before" => "Intermediate", "after" => "Final"}}
             } in payloads
    end

    test "records general changes alongside a dedicated security-setting event" do
      account = Fixtures.Accounts.create_account(name: "Original")
      Fixtures.Accounts.set_account_settings(account, %{require_mfa: true})
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)

      attrs = %{
        name: "Renamed",
        settings: %{require_mfa: false, monthly_report_opt_out: true}
      }

      assert {:ok, _} = Accounts.update_account(account, attrs, subject)
      assert [general] = events("account.updated")
      assert [security] = events("account.require_mfa_set")

      assert general.payload == %{
               "changes" => %{
                 "name" => %{"before" => "Original", "after" => "Renamed"},
                 "monthly_report_opt_out" => %{"before" => false, "after" => true}
               }
             }

      assert security.payload == %{"require_mfa" => false}
      assert Repo.aggregate(Audit.Event, :count) == 2
    end

    test "owned cleanup settings record enabled and disabled periods" do
      account = Fixtures.Accounts.create_account()
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)

      assert {:ok, _} = Accounts.put_account_pack_retention_days(account.id, 30, subject)

      assert {:ok, _} =
               Accounts.put_account_runner_inactive_retention_hours(account.id, 24, subject)

      assert {:ok, _} = Accounts.put_account_pack_retention_days(account.id, nil, subject)

      assert {:ok, _} =
               Accounts.put_account_runner_inactive_retention_hours(account.id, nil, subject)

      payloads = Enum.map(events("account.updated"), & &1.payload)
      assert length(payloads) == 4

      for {field, before_value, after_value} <- [
            {"pack_unseen_retention_days", nil, 30},
            {"runner_inactive_retention_hours", nil, 24},
            {"pack_unseen_retention_days", 30, nil},
            {"runner_inactive_retention_hours", 24, nil}
          ] do
        assert %{
                 "changes" => %{field => %{"before" => before_value, "after" => after_value}}
               } in payloads
      end
    end

    test "unchanged account fields and cleanup settings create no event" do
      account = Fixtures.Accounts.create_account()
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)

      attrs = %{
        name: account.name,
        slug: account.slug,
        settings: %{monthly_report_opt_out: false}
      }

      assert {:ok, _} = Accounts.update_account(account, attrs, subject)
      assert {:ok, _} = Accounts.put_account_pack_retention_days(account.id, nil, subject)

      assert {:ok, _} =
               Accounts.put_account_runner_inactive_retention_hours(account.id, nil, subject)

      refute Repo.one(Audit.Event)
    end

    test "the emailed unsubscribe records its exact change once without a user actor" do
      account = Fixtures.Accounts.create_account()
      token = Crypto.monthly_report_unsubscribe_token(account.id)

      assert {:ok, _} = Accounts.unsubscribe_from_monthly_report(token)
      assert {:ok, _} = Accounts.unsubscribe_from_monthly_report(token)
      assert [event] = events("account.updated")

      assert event.account_id == account.id
      assert event.actor_kind == "system"
      assert event.actor_id == nil

      assert event.payload == %{
               "changes" => %{
                 "monthly_report_opt_out" => %{"before" => false, "after" => true}
               }
             }
    end

    test "denied and cross-account updates produce no receipts" do
      account = Fixtures.Accounts.create_account()
      viewer = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :viewer)
      other_account = Fixtures.Accounts.create_account()
      other_owner = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), other_account)

      assert Accounts.update_account(account, %{name: "Denied"}, viewer) ==
               {:error, :unauthorized}

      assert Accounts.update_account(account, %{name: "Foreign"}, other_owner) ==
               {:error, :unauthorized}

      assert Accounts.put_account_pack_retention_days(account.id, 30, other_owner) ==
               {:error, :not_found}

      assert Accounts.put_account_runner_inactive_retention_hours(account.id, 24, other_owner) ==
               {:error, :not_found}

      refute Repo.one(Audit.Event)
      assert Repo.reload!(account).name == account.name
    end

    test "a rejected update leaves neither changed settings nor a receipt" do
      account = Fixtures.Accounts.create_account()
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)
      attrs = %{slug: "invalid slug", settings: %{monthly_report_opt_out: true}}

      assert {:error, changeset} = Accounts.update_account(account, attrs, subject)

      assert "must be lowercase letters/numbers/hyphens, start with a letter, 3-64 chars" in errors_on(
               changeset
             ).slug

      refute Repo.reload!(account).settings.monthly_report_opt_out
      refute Repo.one(Audit.Event)
    end
  end

  describe "invitation resend receipts" do
    test "resending records its own event with the invitation's role and selected access" do
      {owner, account, subject} = Fixtures.Subjects.owner_subject()
      Fixtures.Runners.create_runner(account_id: account.id, group: "production")

      attrs =
        Fixtures.Accounts.invitation_attrs(
          role: "operator",
          runner_access_mode: "restricted",
          scope: ["group:production"]
        )

      assert {:ok, %{membership: membership, user: invitee, invitation_token: original_token}} =
               Accounts.invite_user_to_account(attrs, subject)

      assert {:ok, %{membership: renewed, invitation_token: renewed_token}} =
               Accounts.resend_account_invitation(membership, subject)

      assert [_invited] = events("user.invited")
      assert [resent] = events("membership.invitation_resent")
      assert resent.account_id == account.id
      assert resent.actor_id == owner.id
      assert resent.target_id == invitee.id
      assert renewed.id == membership.id
      refute renewed_token == original_token

      assert resent.payload == %{
               "role" => "operator",
               "runner_access" => %{
                 "mode" => "restricted",
                 "groups" => ["production"],
                 "runner_ids" => [],
                 "pack_mode" => "all",
                 "pack_ids" => []
               }
             }
    end

    test "denied and foreign-account resends create no resend event" do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject()
      attrs = Fixtures.Accounts.invitation_attrs()
      assert {:ok, %{membership: membership}} = Accounts.invite_user_to_account(attrs, subject)

      viewer = Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer")
      viewer_subject = Fixtures.Subjects.membership_subject(viewer)
      foreign_owner = Fixtures.Memberships.create_membership(role: "owner")
      foreign_subject = Fixtures.Subjects.membership_subject(foreign_owner)

      assert Accounts.resend_account_invitation(membership, viewer_subject) ==
               {:error, :unauthorized}

      assert Accounts.resend_account_invitation(membership, foreign_subject) ==
               {:error, :unauthorized}

      assert events("membership.invitation_resent") == []
      assert [_invited] = events("user.invited")

      assert Repo.reload!(membership).invitation_token_digest ==
               membership.invitation_token_digest
    end
  end

  defp events(type) do
    Audit.Event.Query.all()
    |> Audit.Event.Query.by_event_type(type)
    |> Repo.all()
  end
end
