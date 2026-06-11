defmodule Emisar.Repo.Migrations.HashInvitationTokensAtRest do
  use Ecto.Migration

  @moduledoc """
  Corrective (prod already ran the original memberships migration):
  invitation tokens move to the same mint→hash contract as every other
  bearer credential — only `sha256(raw)` (url-safe base64, matching
  `Emisar.Crypto.user_invite_token_digest/1`) is at rest, so a DB leak
  no longer exposes live invite links. Existing stored raw tokens are
  hashed in place so pending invite emails keep working; the column is
  renamed to say what it now holds.
  """

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS pgcrypto"

    execute """
    UPDATE memberships
    SET invitation_token =
      translate(rtrim(encode(digest(invitation_token, 'sha256'), 'base64'), '='), '+/', '-_')
    WHERE invitation_token IS NOT NULL
    """

    rename table(:memberships), :invitation_token, to: :invitation_token_digest
  end

  def down do
    # Raw tokens are unrecoverable from digests — down only restores the
    # column name; pending invitations must be re-sent.
    rename table(:memberships), :invitation_token_digest, to: :invitation_token
  end
end
