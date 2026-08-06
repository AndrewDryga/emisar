defmodule Emisar.Repo.Migrations.WidenApprovalDecisionReason do
  use Ecto.Migration

  def change do
    # The approver's decision note is free text an operator types into a textarea,
    # and it was still the varchar(255) the table was created with. Nothing bounded
    # it on the way in: decide_pending/5 writes it through a bare update_all, so
    # there is no changeset to validate against, and the textarea carried no
    # maxlength. A note longer than roughly two sentences therefore raised
    # Postgres 22001 inside the decision transaction — a raise, not a changeset
    # error — which killed the LiveView, left the request pending AND its gated
    # run parked in pending_approval, and wrote no approval audit row at all. The
    # security ceremony failed with a crash and no record.
    #
    # 20260820000000 widened action_runs.reason and approval_requests.reason to
    # :text for the same reason and did not carry decision_reason with them. This
    # is that column. Widening is data-safe; the domain-side length bound lands
    # with it so the operator gets an inline error instead of a 22001.
    alter table(:approval_requests) do
      modify :decision_reason, :text, from: :string
    end
  end
end
