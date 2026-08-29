defmodule Emisar.ClearUnverifiedOidcLinkMatchesTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Fixtures, Repo}

  test "the forward repair clears only unverified OIDC account preselection" do
    account = Fixtures.Accounts.create_account()
    provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
    member = Fixtures.Users.create_user()
    Fixtures.Memberships.create_membership(account_id: account.id, user_id: member.id)

    cases = [
      {:oidc, %{}, nil},
      {:oidc, %{"email_verified" => false}, nil},
      {:oidc, %{"email_verified" => "false"}, nil},
      {:oidc, %{"email_verified" => true}, member.id},
      {:oidc, %{"email_verified" => "true"}, member.id},
      {:scim, %{}, member.id}
    ]

    requests =
      for {{source, claims, expected_match}, index} <- Enum.with_index(cases) do
        request =
          Fixtures.SSO.create_link_request(
            provider: provider,
            provider_identifier: "legacy-#{index}",
            source: source,
            claims: Map.put(claims, "email", member.email),
            email: member.email,
            matched_user_id: member.id
          )

        {request, expected_match}
      end

    migration = Emisar.Repo.Migrations.ClearUnverifiedOidcLinkMatches

    unless Code.ensure_loaded?(migration) do
      Code.require_file(
        Path.expand(
          "../../priv/repo/migrations/20260929000000_clear_unverified_oidc_link_matches.exs",
          __DIR__
        )
      )
    end

    repair_sql = Function.capture(migration, :repair_sql, 0)
    Repo.query!(repair_sql.())

    for {request, expected_match} <- requests do
      assert Repo.reload!(request).matched_user_id == expected_match
    end
  end
end
