defmodule Emisar.Repo.Migrations.AddEnumCheckBackstops do
  use Ecto.Migration

  # DB CHECK backstops for the security-relevant Ecto.Enum columns. Every app
  # write path already casts through Ecto.Enum; these guard the raw-SQL /
  # migration-bug path, where one invalid value would crash the read path on
  # load. Value lists mirror the schema modules — extending an enum needs a
  # new migration replacing its CHECK in the same change.

  def change do
    create constraint(:account_memberships, :account_memberships_role_check,
             check: "role IN ('owner', 'admin', 'billing_manager', 'operator', 'viewer')"
           )

    create constraint(:catalog_runner_actions, :catalog_runner_actions_kind_check,
             check: "kind IN ('exec', 'script')"
           )

    create constraint(:catalog_runner_actions, :catalog_runner_actions_risk_check,
             check: "risk IN ('low', 'medium', 'high', 'critical')"
           )

    create constraint(:action_runs, :action_runs_source_check,
             check: "source IN ('operator', 'runbook', 'mcp', 'scheduled')"
           )

    create constraint(:action_runs, :action_runs_status_check,
             check:
               "status IN ('pending', 'pending_approval', 'denied', 'sent', 'running', 'cancelling', 'success', 'failed', 'error', 'validation_failed', 'unknown_action', 'cancelled', 'timed_out', 'refused')"
           )

    create constraint(:approval_requests, :approval_requests_status_check,
             check: "status IN ('pending', 'approved', 'denied', 'expired', 'cancelled')"
           )

    create constraint(:approval_requests, :approval_requests_min_approvals_check,
             check: "min_approvals >= 1"
           )

    create constraint(:approval_decisions, :approval_decisions_decision_check,
             check: "decision IN ('approve', 'deny')"
           )

    create constraint(:catalog_pack_versions, :catalog_pack_versions_trust_state_check,
             check: "trust_state IN ('trusted', 'pending', 'rejected')"
           )
  end
end
