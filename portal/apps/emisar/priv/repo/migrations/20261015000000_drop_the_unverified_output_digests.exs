defmodule Emisar.Repo.Migrations.DropTheUnverifiedOutputDigests do
  use Ecto.Migration

  # Every run stored two SHA-256 digests of its emitted output, written from
  # the runner's terminal payload and read by nothing — the verifier they were
  # for was never built, and the founder decided (2026-08-28) it will not be.
  # The byte counts stay: the MCP result summary reads them. The host-side
  # journal keeps its own digests of the redacted output; that record is the
  # tamper-evidence story, and it never depended on these columns.
  def change do
    alter table(:action_runs) do
      remove :emitted_stdout_sha256, :string
      remove :emitted_stderr_sha256, :string
    end
  end
end
