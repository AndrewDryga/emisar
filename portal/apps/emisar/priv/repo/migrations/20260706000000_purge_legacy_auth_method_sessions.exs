defmodule Emisar.Repo.Migrations.PurgeLegacyAuthMethodSessions do
  use Ecto.Migration

  # Corrective DATA migration (not edit-original). The passwordless rework
  # narrowed user_tokens.auth_method to [:magic_link, :sso] without cleaning
  # the rows already holding the dropped `:password` value, so those session
  # tokens raised `(ArgumentError) cannot load "password" as type Ecto.Enum`
  # on load and 500'd the auth path. Delete any token whose auth_method is no
  # longer a valid enum value — these are invalidated sessions, so the user
  # simply re-authenticates via magic link. No-op on fresh DBs (no such rows);
  # already applied by hand to prod on 2026-06-29, this records it and covers
  # any other environment or a backup-restore. The query hardening in
  # UserToken.Query.with_valid_auth_method/1 is the defense-in-depth pair.
  def up do
    execute("""
    DELETE FROM user_tokens
    WHERE auth_method IS NOT NULL
      AND auth_method NOT IN ('magic_link', 'sso')
    """)
  end

  # Irreversible: a deleted session can't be reconstructed — and shouldn't be,
  # it authenticated via a method that no longer exists.
  def down, do: :ok
end
