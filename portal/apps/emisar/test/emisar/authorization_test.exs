defmodule Emisar.AuthorizationTest do
  @moduledoc """
  Critical-path coverage for the Subject + Authorizer gates. Every
  refactored context should refuse `{:error, :unauthorized}` when a
  subject lacks the relevant permission — without this, a regression
  to "permissionless = full access" wouldn't show up in feature tests.
  """
  use Emisar.DataCase, async: true
  alias Emisar.Accounts.Membership
  alias Emisar.Auth.Subject
  alias Emisar.Fixtures

  defp subject_with_role(account, role) do
    user = Fixtures.Users.create_user()

    Subject.for_user(
      user,
      account,
      %Membership{role: Atom.to_string(role), user_id: user.id, account_id: account.id}
    )
  end

  describe "Audit reads" do
    test "viewer can list events" do
      account = Fixtures.Accounts.create_account()
      subject = subject_with_role(account, :viewer)
      assert {:ok, _events, _meta} = Emisar.Audit.list_events(subject)
    end

    test "unauthorized subject is rejected" do
      # Account-less subject with the empty permission set — emulates a
      # caller from before login completes / from a misconfigured plug.
      subject = %Subject{account: nil, role: nil, permissions: MapSet.new()}
      assert {:error, :unauthorized} = Emisar.Audit.list_events(subject)
      assert {:error, :unauthorized} = Emisar.Audit.list_events(subject, page: [limit: 5])
    end

    test "list_events scopes to the subject's account (cross-account isolation)" do
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()

      {:ok, _} = Emisar.Audit.log(account_a.id, "in.a", actor_kind: "system")
      {:ok, _} = Emisar.Audit.log(account_b.id, "in.b", actor_kind: "system")

      subject = subject_with_role(account_a, :viewer)

      {:ok, events, _} = Emisar.Audit.list_events(subject)
      assert Enum.all?(events, &(&1.account_id == account_a.id))
      refute Enum.any?(events, &(&1.event_type == "in.b"))
    end

    test "fetch_event_by_id refuses an event from another account" do
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()

      {:ok, event_in_b} = Emisar.Audit.log(account_b.id, "secret.in.b", actor_kind: "system")

      subject = subject_with_role(account_a, :viewer)
      assert {:error, :not_found} = Emisar.Audit.fetch_event_by_id(event_in_b.id, subject)
    end
  end

  describe "Policies" do
    setup do
      account = Fixtures.Accounts.create_account()
      seed_policy_for(account)
      %{account: account}
    end

    test "viewer can fetch the policy", %{account: account} do
      subject = subject_with_role(account, :viewer)
      assert {:ok, _policy} = Emisar.Policies.fetch_policy(subject)
    end

    test "viewer is rejected from save_rules", %{account: account} do
      subject = subject_with_role(account, :viewer)

      assert {:error, :unauthorized} =
               Emisar.Policies.save_rules(
                 %{"schema_version" => 2, "defaults" => %{}, "overrides" => []},
                 subject
               )
    end

    test "admin can save_rules", %{account: account} do
      subject = subject_with_role(account, :admin)

      new_rules = %{
        "schema_version" => 2,
        "defaults" => %{
          "low" => "allow",
          "medium" => "allow",
          "high" => "deny",
          "critical" => "deny"
        },
        "overrides" => [],
        "approval" => %{"min_approvals" => 1, "allow_self_approval" => true}
      }

      assert {:ok, updated} = Emisar.Policies.save_rules(new_rules, subject)

      assert updated.rules == new_rules
    end

    test "fetch_policy from a foreign account returns :not_found, not :unauthorized" do
      # The Authorizer's `for_subject` scopes by account, so a foreign
      # policy is simply invisible — :not_found is the right shape
      # (mirrors what an opaque-id-based attacker would see).
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()
      _ = seed_policy_for(account_b)

      subject = subject_with_role(account_a, :owner)
      # account_a never had a policy seeded → :not_found regardless.
      assert {:error, :not_found} = Emisar.Policies.fetch_policy(subject)
    end
  end

  describe "Runbooks" do
    setup do
      %{account: Fixtures.Accounts.create_account()}
    end

    test "viewer can list runbooks", %{account: account} do
      subject = subject_with_role(account, :viewer)
      assert {:ok, _list, _meta} = Emisar.Runbooks.list_runbooks(subject)
    end

    test "viewer is rejected from create_runbook", %{account: account} do
      subject = subject_with_role(account, :viewer)

      assert {:error, :unauthorized} =
               Emisar.Runbooks.create_runbook(
                 %{
                   "name" => "x",
                   "slug" => "x",
                   "title" => "X",
                   "definition" => %{"steps" => []}
                 },
                 subject
               )
    end

    test "admin can create_runbook", %{account: account} do
      subject = subject_with_role(account, :admin)

      assert {:ok, _rb} =
               Emisar.Runbooks.create_runbook(
                 %{
                   name: "smoke",
                   slug: "smoke",
                   title: "Smoke test",
                   definition: %{"steps" => []}
                 },
                 subject
               )
    end

    test "admin can create_runbook from string-keyed form params", %{account: account} do
      subject = subject_with_role(account, :admin)

      # The LiveView form submits string keys; the context must not merge an
      # atom :version into them — that produced a mixed-key map and crashed cast.
      assert {:ok, runbook} =
               Emisar.Runbooks.create_runbook(
                 %{
                   "name" => "from-form",
                   "slug" => "from-form",
                   "title" => "From the form",
                   "description" => "",
                   "status" => "published",
                   "definition" => %{
                     "steps" => [
                       %{
                         "id" => "1",
                         "action_id" => "nomad.job_status_all",
                         "args" => %{},
                         "runner_selector" => %{"group" => ["ops"]}
                       }
                     ]
                   }
                 },
                 subject
               )

      assert runbook.version == 1
    end
  end

  describe "Runbooks cross-account isolation (two-gates)" do
    setup do
      {_owner_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      {:ok, runbook_b} =
        Emisar.Runbooks.create_runbook(
          %{
            name: "ops-#{System.unique_integer()}",
            slug: "ops-#{System.unique_integer()}",
            title: "Restart",
            description: "b's runbook",
            definition: %{"steps" => []}
          },
          subject_b
        )

      account_a = Fixtures.Accounts.create_account()
      %{runbook_b: runbook_b, subject_a: subject_with_role(account_a, :owner)}
    end

    test "an owner of A can't save a new version of B's runbook (permission held, account not)",
         %{runbook_b: runbook_b, subject_a: subject_a} do
      assert {:error, :not_found} =
               Emisar.Runbooks.save_new_version(runbook_b, %{description: "hijacked"}, subject_a)
    end

    test "an owner of A can't dispatch B's runbook", %{
      runbook_b: runbook_b,
      subject_a: subject_a
    } do
      assert {:error, :not_found} =
               Emisar.Runbooks.dispatch_runbook(runbook_b, "go", subject_a)
    end
  end

  describe "Authorizer.for_subject/2 fail-closed fallback" do
    # A subject matching no scoping clause must see ZERO rows, not unscoped
    # rows — defense-in-depth for any future path that calls for_subject
    # without the permission gate. Runners + Runs have the same coverage
    # beside their runner-actor scoping tests.

    test "SSO.Authorizer closes an unrecognized query source, not just an unmatched subject" do
      # This authorizer branches on the query source inside its account clause, so
      # it has a SECOND fallback the others don't. A source it has no clause for
      # used to come back unscoped — every account's rows — for a subject that
      # passed the account match.
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.membership_subject(membership)
      Fixtures.Runbooks.create_runbook(account_id: account.id)

      # A queryable SSO.Authorizer has no clause for.
      rows =
        Emisar.Runbooks.Runbook.Query.all()
        |> Emisar.SSO.Authorizer.for_subject(subject)
        |> Repo.all()

      assert rows == []
    end

    test "ApiKeys.Authorizer scopes an unmatched subject to zero rows" do
      account = Fixtures.Accounts.create_account()
      Fixtures.ApiKeys.create_api_key(account_id: account.id)
      bare_subject = Fixtures.Subjects.build_subject()

      rows =
        Emisar.ApiKeys.ApiKey.Query.all()
        |> Emisar.ApiKeys.Authorizer.for_subject(bare_subject)
        |> Repo.all()

      assert rows == []
    end

    test "Catalog.Authorizer scopes an unmatched subject to zero rows" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      Fixtures.Catalog.create_action(runner: runner)
      Fixtures.Catalog.create_trusted_pack_version(account_id: account.id)
      bare_subject = Fixtures.Subjects.build_subject()

      action_rows =
        Emisar.Catalog.RunnerAction.Query.all()
        |> Emisar.Catalog.Authorizer.for_subject(bare_subject)
        |> Repo.all()

      # The fallback's `none/1` is binding-free, so it also closes a queryable
      # of the authorizer's OTHER schema (PackVersion via RunnerAction.Query.none).
      pack_version_rows =
        Emisar.Catalog.PackVersion.Query.all()
        |> Emisar.Catalog.Authorizer.for_subject(bare_subject)
        |> Repo.all()

      assert action_rows == []
      assert pack_version_rows == []
    end

    test "Runbooks.Authorizer scopes an unmatched subject to zero rows" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Runbooks.create_runbook(account_id: account.id)
      bare_subject = Fixtures.Subjects.build_subject()

      rows =
        Emisar.Runbooks.Runbook.Query.all()
        |> Emisar.Runbooks.Authorizer.for_subject(bare_subject)
        |> Repo.all()

      assert rows == []
    end

    test "Policies.Authorizer scopes an unmatched subject to zero rows" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Policies.create_policy(account_id: account.id)
      bare_subject = Fixtures.Subjects.build_subject()

      rows =
        Emisar.Policies.Policy.Query.all()
        |> Emisar.Policies.Authorizer.for_subject(bare_subject)
        |> Repo.all()

      assert rows == []
    end

    test "SSO.Authorizer scopes an unmatched subject to zero rows" do
      account = Fixtures.Accounts.create_account()
      Fixtures.SSO.create_identity_provider(account_id: account.id)
      bare_subject = Fixtures.Subjects.build_subject()

      rows =
        Emisar.SSO.IdentityProvider.Query.all()
        |> Emisar.SSO.Authorizer.for_subject(bare_subject)
        |> Repo.all()

      assert rows == []
    end

    test "MCPOperations.Authorizer scopes an unmatched subject to zero rows" do
      account = Fixtures.Accounts.create_account()
      Fixtures.MCPOperations.create_operation(account_id: account.id)
      bare_subject = Fixtures.Subjects.build_subject()

      rows =
        Emisar.MCPOperations.Operation.Query.all()
        |> Emisar.MCPOperations.Authorizer.for_subject(bare_subject)
        |> Repo.all()

      assert rows == []
    end

    test "Audit.Authorizer scopes an unmatched subject to zero rows" do
      account = Fixtures.Accounts.create_account()
      {:ok, _event} = Emisar.Audit.log(account.id, "authz.probe", actor_kind: "system")
      bare_subject = Fixtures.Subjects.build_subject()

      rows =
        Emisar.Audit.Event.Query.all()
        |> Emisar.Audit.Authorizer.for_subject(bare_subject)
        |> Repo.all()

      assert rows == []
    end

    test "Accounts.Authorizer scopes an unmatched subject to zero rows" do
      Fixtures.Accounts.create_account()
      bare_subject = Fixtures.Subjects.build_subject()

      rows =
        Emisar.Accounts.Account.Query.all()
        |> Emisar.Accounts.Authorizer.for_subject(bare_subject)
        |> Repo.all()

      assert rows == []
    end

    test "Approvals.Authorizer scopes an unmatched subject to zero rows" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Approvals.create_request(account_id: account.id)
      bare_subject = Fixtures.Subjects.build_subject()

      rows =
        Emisar.Approvals.Request.Query.all()
        |> Emisar.Approvals.Authorizer.for_subject(bare_subject)
        |> Repo.all()

      assert rows == []
    end

    test "Billing.Authorizer scopes an unmatched subject to zero rows" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Accounts.create_subscription(account, "team")
      bare_subject = Fixtures.Subjects.build_subject()

      rows =
        Emisar.Billing.Subscription.Query.all()
        |> Emisar.Billing.Authorizer.for_subject(bare_subject)
        |> Repo.all()

      assert rows == []
    end
  end

  # -- helpers --------------------------------------------------------

  defp seed_policy_for(account) do
    user = Fixtures.Users.create_user()

    {:ok, _} =
      Emisar.Policies.seed_policy(account.id, user.id, %{
        "schema_version" => 2,
        "defaults" => %{
          "low" => "allow",
          "medium" => "allow",
          "high" => "require_approval",
          "critical" => "deny"
        },
        "overrides" => [],
        "approval" => %{"min_approvals" => 1, "allow_self_approval" => true}
      })

    Emisar.Policies.peek_policy_for_account(account.id)
  end
end
