defmodule Emisar.Repo.Migrations.FinishTheEnumCheckBackstops do
  use Ecto.Migration

  # 20260816000002 set the policy: every security-relevant Ecto.Enum column gets
  # a DB CHECK, guarding the raw-SQL and migration-bug paths the app's own
  # Ecto.Enum cast cannot see. Five columns were missed. Value lists mirror the
  # schema modules — extending an enum needs a new migration replacing its CHECK
  # in the same change.
  #
  # sso_identity_providers.kind is deliberately NOT here. It is an Ecto.Enum
  # too, but its values come from ProviderKind's metadata list, which grows
  # every time we support another IdP; a CHECK would make each addition a
  # migration for a column fed by a closed console picker rather than by runner
  # or LLM input.

  def up do
    # A CHECK validates the rows already there, so a session written before the
    # passwordless rework narrowed this enum would fail the ALTER and take the
    # deploy with it. Such a row already cannot authenticate — the read path
    # filters it to not-found — so sweeping it is what the app already does.
    execute("""
    DELETE FROM auth_user_tokens
    WHERE auth_method IS NOT NULL AND auth_method NOT IN ('magic_link', 'sso')
    """)

    # Runner-supplied: the runner names the kind on every streamed event.
    create constraint(:action_run_events, :action_run_events_kind_check,
             check: "kind IN ('progress', 'transition', 'error')"
           )

    # The MFA constraint on this table already pins auth_method, but only for
    # rows carrying mfa_enrollment_verified_at — an ordinary session row's
    # method was unconstrained, which is why the read path had to filter
    # defensively. See UserToken.Query.
    create constraint(:auth_user_tokens, :auth_user_tokens_auth_method_check,
             check: "auth_method IS NULL OR auth_method IN ('magic_link', 'sso')"
           )

    # The claim an OIDC binding is keyed on. Its schema comment names the
    # takeover a wrong value permits.
    create constraint(:sso_identity_providers, :sso_identity_providers_identifier_claim_check,
             check: "identifier_claim IN ('sub', 'oid')"
           )

    create constraint(:policies, :policies_scope_type_check,
             check: "scope_type IN ('account', 'runner', 'group')"
           )

    create constraint(:api_keys, :api_keys_kind_check, check: "kind IN ('mcp', 'audit_export')")
  end

  def down do
    drop constraint(:api_keys, :api_keys_kind_check)
    drop constraint(:policies, :policies_scope_type_check)
    drop constraint(:sso_identity_providers, :sso_identity_providers_identifier_claim_check)
    drop constraint(:auth_user_tokens, :auth_user_tokens_auth_method_check)
    drop constraint(:action_run_events, :action_run_events_kind_check)
  end
end
