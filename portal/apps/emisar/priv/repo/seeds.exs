# Seeds for local dev. Run with `mix ecto.seed` (or `./run seed` against the
# docker stack). Idempotent — safe to re-run.
#
# Goal: produce a believable live-account state so the dashboard,
# runs list, approvals, runners, audit, and grants pages all show
# real-shaped data when an operator first opens the app — instead of
# empty-state cards everywhere.
#
# Each section lives in seeds/<section>.exs as an Emisar.Seeds.* module. The
# sequence below is the account's story in order, and every step hands the
# next one the context it needs: the owner and account, the teammates, the
# runners, the runbooks, the seeded executions, the agent key.

for file <- ~w(
      helpers
      demo_account
      runbooks
      fleet
      runbook_executions
      agents
      action_runs
      sso
      plan_accounts
      staff_account
    ) do
  Code.require_file("seeds/#{file}.exs", __DIR__)
end

alias Emisar.Seeds.{ActionRuns, Agents, DemoAccount, Fleet, PlanAccounts}
alias Emisar.Seeds.{RunbookExecutions, Runbooks, SSO, StaffAccount}

# Approval emails go through Swoosh; in dev that's fine, but the seed
# shouldn't depend on the mailer being reachable.
Application.put_env(:emisar, :notify_approvers_async?, false)

ctx = DemoAccount.run()
ctx = Runbooks.run(ctx)
ctx = Fleet.run(ctx)
ctx = RunbookExecutions.run(ctx)
ctx = Agents.run(ctx)

# The run history seeds only into an account with no runs, so it has to look
# before the runbook attempts and the typed run below add theirs.
ActionRuns.run(ctx)
RunbookExecutions.seed_output_previews(ctx)
Fleet.seed_enrollment_key(ctx)
ActionRuns.seed_typed_json_run(ctx)

SSO.run(ctx)
PlanAccounts.run(ctx)
StaffAccount.run()
