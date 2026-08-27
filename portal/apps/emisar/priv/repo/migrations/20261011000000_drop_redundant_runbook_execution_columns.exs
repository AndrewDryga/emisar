defmodule Emisar.Repo.Migrations.DropRedundantRunbookExecutionColumns do
  use Ecto.Migration

  # Both columns were written and never read.
  #
  # `halted_at` was set by halt/4 and cancel/2 — and in both, to the same value
  # as `completed_at` in the same change. Nothing ever read it: the terminal
  # moment is `completed_at`, and which KIND of terminal it was is `status`.
  #
  # `sensitive_input_names` recorded which supplied inputs were declared
  # sensitive. Masking does not use it and never did: the compiler enforces the
  # sensitive-binding contract at compile time, and every surface that renders a
  # value (execution_projection, extractor) reads `sensitive` off the input
  # declaration in `definition` — which the execution row stores itself, and
  # digests as `definition_sha256`. So the list was a third copy of a fact
  # already on the row twice, and any reader that wants it can derive it.
  #
  # The sibling `action_runs.sensitive_arg_names` is a different column on a
  # different table, IS read (runs.ex), and is untouched here.
  def change do
    alter table(:runbook_executions) do
      remove :halted_at, :utc_datetime_usec
      remove :sensitive_input_names, {:array, :string}, null: false, default: []
    end
  end
end
