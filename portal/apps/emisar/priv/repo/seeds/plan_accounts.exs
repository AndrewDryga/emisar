defmodule Emisar.Seeds.PlanAccounts do
  @moduledoc """
  Extra accounts: the plan tiers plus an empty one, so the billing / upsell /
  runner-limit states AND the SSO-is-Enterprise gate are all visible by
  switching accounts in one seeded dev DB (the main "demo" account is
  enterprise, so SSO/SCIM is testable there), and a "both connected, no
  actions" account for the onboarding checklist.
  """

  alias Emisar.Accounts
  alias Emisar.ApiKeys
  alias Emisar.Auth.Subject
  alias Emisar.Repo
  alias Emisar.Runners
  alias Emisar.Runs
  alias Emisar.Seeds.{Fleet, Helpers}

  def run(ctx) do
    # Free + Team accounts WITH data (a runner + two finished runs each) so a
    # non-enterprise account looks lived-in and its plan's runner limit shows.
    for {name, slug, plan} <- [
          {"Acme Logistics Demo", "acme", "free"},
          {"Globex Platform Demo", "globex", "team"}
        ] do
      seed_plan_account_with_data(name, slug, plan)
    end

    # An empty Free account — to see the onboarding / empty-state surfaces.
    _ = seed_plan_account("Blank Workspace Demo", "blank", "free")
    Helpers.say("✓ Blank Workspace Demo (slug=blank, free) — empty")

    seed_both_connected_account(ctx)
    :ok
  end

  defp seed_plan_account(name, slug, plan) do
    owner = Helpers.ensure_persona("owner@#{slug}.test", "#{name} Owner")
    acct = Helpers.ensure_account(name, slug, owner)
    {:ok, membership} = Accounts.fetch_membership_for_session(owner, acct.id)
    subject = Subject.for_user(owner, acct, membership)
    acct = Helpers.ensure_account_name(acct, name, subject)

    Helpers.seed_subscription(acct, plan)

    # Reconcile the Paddle link to the persona so a reseed can't leave an account
    # wearing a prior run's customer id — a stale id lights up "Manage subscription"
    # and the stub PaddleClient's fake invoices on a page that should show none (the
    # Blank Workspace free account did exactly this). Only the team persona is
    # self-serve in dev; every other tier is nil.
    paddle_customer_id = if plan == "team", do: "ctm_dev_#{slug}", else: nil

    acct =
      acct
      |> Ecto.Changeset.change(paddle_customer_id: paddle_customer_id)
      |> Repo.update!()

    subject = Subject.for_user(owner, acct, membership)

    {acct, owner, subject}
  end

  defp seed_plan_account_with_data(name, slug, plan) do
    {acct, owner, subject} = seed_plan_account(name, slug, plan)

    runner_name = "#{slug}-prod-1"

    runner =
      case Runners.fetch_runner_by_name(runner_name, subject) do
        {:ok, existing} ->
          existing

        {:error, :not_found} ->
          {:ok, created} =
            Helpers.insert_seed_runner(acct.id, %{name: runner_name, group: "prod"})

          created
      end
      |> Ecto.Changeset.change(
        hostname: "#{runner_name}.example",
        labels: %{"env" => "prod", "account" => slug},
        last_connected_at: Helpers.mins_ago(35),
        runner_version: Emisar.Compat.runner_target()
      )
      |> Repo.update!()

    Fleet.advertise(runner, Fleet.linux_actions())

    existing_account_runs =
      case Runs.list_recent_runs(subject, limit: 1) do
        {:ok, rows, _metadata} -> rows
        _ -> []
      end

    if existing_account_runs == [] do
      for {action, hrs, args, reason} <- [
            {"linux.uptime", 2, %{}, "spot check after runner install"},
            {"linux.disk_usage", 9, %{"paths" => ["/"]}, "daily capacity check"}
          ] do
        {:ok, run} =
          Runs.create_run(%{
            account_id: acct.id,
            runner_id: runner.id,
            action_id: action,
            args: args,
            reason: reason,
            source: "operator",
            requested_by_id: owner.id
          })

        run
        |> Ecto.Changeset.change(
          status: :success,
          inserted_at: Helpers.hours_ago(hrs),
          queued_at: Helpers.hours_ago(hrs),
          finished_at: DateTime.add(Helpers.hours_ago(hrs), 1, :second),
          exit_code: 0,
          duration_ms: 1000
        )
        |> Repo.update!()
      end
    end

    Helpers.say("✓ #{name} (slug=#{slug}, #{plan}) — with data")
  end

  # A "both connected, no actions" account — one runner AND one agent, but the
  # runner advertises an empty catalog — so the onboarding checklist must explain
  # how to install a catalog pack before offering a run prompt. Demo-owned, reachable by
  # switching accounts as demo. Existence-checked, so it repairs the account demo
  # already made by hand rather than duplicating its runner.
  defp seed_both_connected_account(%{user: user}) do
    both_connected_account = Helpers.ensure_account("Both Connected Co", "both-connected", user)

    {:ok, bc_membership} =
      Accounts.fetch_membership_for_session(user, both_connected_account.id)

    bc_subject = Subject.for_user(user, both_connected_account, bc_membership)

    bc_runner =
      case Runners.list_all_runners_for_account(bc_subject) do
        {:ok, [runner | _]} ->
          runner

        _ ->
          {:ok, runner} =
            Helpers.insert_seed_runner(both_connected_account.id, %{
              name: "both-connected-prod-1",
              group: "prod"
            })

          runner
          |> Ecto.Changeset.change(
            hostname: "both-connected-prod-1.example",
            last_connected_at: Helpers.mins_ago(20),
            runner_version: Emisar.Compat.runner_target()
          )
          |> Repo.update!()
      end

    Fleet.advertise(bc_runner, [])

    case ApiKeys.list_api_keys_for_account(bc_subject, page: [limit: 10]) do
      {:ok, [_ | _], _} ->
        :ok

      _ ->
        {:ok, _raw, _key} =
          ApiKeys.create_key(
            %{
              name: "Claude Code",
              description: "MCP client for triage"
            },
            bc_subject
          )
    end

    Helpers.say("✓ Both Connected Co (slug=both-connected) — runner + agent, no actions")
  end
end
