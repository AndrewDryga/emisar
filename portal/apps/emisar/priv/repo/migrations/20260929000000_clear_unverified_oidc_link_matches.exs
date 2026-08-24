defmodule Emisar.Repo.Migrations.ClearUnverifiedOidcLinkMatches do
  @moduledoc """
  OIDC once treated any provider's `hd` claim as authority for the accompanying
  email, so a pending approval could preselect an existing member without
  `email_verified`.

  The pending binding is deterministic and safe to remove. Historical user
  addresses are not: consumed magic links and enrollment proofs can establish a
  real inbox without leaving enough state to distinguish them from the original
  SSO stamp. Do not guess destructively. Pending requests keep their raw display
  claims but lose the unproved account binding; a later verified callback can
  upsert it again.
  """
  use Ecto.Migration

  @repair_sql """
  UPDATE sso_link_requests
  SET matched_user_id = NULL,
      updated_at = now()
  WHERE source = 'oidc'
    AND matched_user_id IS NOT NULL
    AND claims->>'email_verified' IS DISTINCT FROM 'true'
  """

  @doc false
  def repair_sql, do: @repair_sql

  def up, do: execute(@repair_sql)

  # The removed preselection was never an identity credential and cannot be
  # reconstructed safely without a fresh verified callback.
  def down, do: :ok
end
