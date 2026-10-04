defmodule Emisar.AuthSignUpTest do
  @moduledoc """
  Self-serve sign-up: the owner's address is proved by an emailed split code
  before anything exists. `Auth.request_sign_up_code/2` writes only the code,
  with the intent on it; `Auth.complete_sign_up/3` consumes the proved code
  first and creates the workspace, its owner and the session in that one
  transaction. The lock races live in `auth_sign_up_concurrency_test.exs`.
  """
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Audit, Auth, Crypto, RequestContext}
  alias Emisar.Accounts.{Account, Membership, SignUpInput}
  alias Emisar.Auth.UserToken
  alias Emisar.Fixtures

  @context %RequestContext{}
  @invalid {:error, :invalid_or_expired}

  defp sign_up_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "email" => Fixtures.Random.unique_email(),
        "full_name" => "Ada Lovelace",
        "account_name" => "Analytical Engines #{System.unique_integer([:positive])}"
      },
      Map.new(overrides, fn {key, value} -> {to_string(key), value} end)
    )
  end

  # The code only leaves Auth by email.
  defp request_code(attrs) do
    assert {:ok, %{token_id: token_id, nonce: nonce, delivery: {:ok, :sent}}} =
             Auth.request_sign_up_code(attrs, @context)

    assert_received {:email, sent}
    assert sent.to == [{"", attrs["email"]}]
    [_, ^token_id, secret] = Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", sent.text_body)
    %{token_id: token_id, nonce: nonce, secret: secret}
  end

  defp verified_code(attrs) do
    code = request_code(attrs)
    assert Auth.verify_magic_link(code.token_id, code.secret, code.nonce) == {:ok, nil}
    code
  end

  defp sign_up_codes(email) do
    UserToken.Query.by_context("sign_up")
    |> UserToken.Query.by_sent_to(email)
    |> Repo.all()
  end

  defp members_with(email) do
    Membership.Query.not_deleted()
    |> Membership.Query.by_email(email)
    |> Repo.all()
  end

  defp account_count, do: Repo.aggregate(Account, :count)

  defp browser_id, do: Crypto.random_secret()

  defp minutes_ago(minutes), do: DateTime.add(DateTime.utc_now(), -minutes, :minute)

  describe "request_sign_up_code/2" do
    test "emails a split code and keeps the intent on it; no workspace, Member or slug exists yet" do
      attrs = sign_up_attrs()
      accounts_before = account_count()
      code = request_code(attrs)

      assert [token] = sign_up_codes(attrs["email"])
      assert token.id == code.token_id
      assert token.context == "sign_up"
      assert is_nil(token.account_id)
      assert is_nil(token.membership_id)
      assert token.sent_to == attrs["email"]
      assert token.remaining_attempts == 5

      assert token.metadata == %{
               "account_name" => attrs["account_name"],
               "full_name" => "Ada Lovelace"
             }

      # Only the digest of both halves is stored.
      assert token.token == Crypto.magic_link_digest(code.nonce, code.secret)
      refute inspect(token) =~ code.secret

      assert members_with(attrs["email"]) == []
      assert account_count() == accounts_before
    end

    test "an invalid submission is refused with its changeset and sends nothing" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Auth.request_sign_up_code(
                 %{"email" => "not-an-address", "account_name" => " "},
                 @context
               )

      assert %{email: [_ | _], account_name: [_ | _]} = errors_on(changeset)
      refute_received {:email, _}
      assert UserToken.Query.by_context("sign_up") |> Repo.all() == []
    end

    test "a new code replaces the address's outstanding one, whatever its case" do
      attrs = sign_up_attrs(email: "ada-#{System.unique_integer([:positive])}@example.test")
      first = request_code(attrs)
      second = request_code(%{attrs | "email" => String.upcase(attrs["email"])})

      assert [token] = sign_up_codes(attrs["email"])
      assert token.id == second.token_id

      assert Auth.verify_magic_link(first.token_id, first.secret, first.nonce) == @invalid
      assert Auth.verify_magic_link(second.token_id, second.secret, second.nonce) == {:ok, nil}
    end
  end

  describe "resend_email_code/2 — sign-up" do
    test "re-issues a code to the stored address with the stored intent, replacing the prior one" do
      attrs = sign_up_attrs()
      first = request_code(attrs)

      assert {:ok, %{token_id: second_id, nonce: nonce, delivery: {:ok, :sent}}} =
               Auth.resend_email_code(first.token_id, @context)

      assert_received {:email, sent}
      assert sent.to == [{"", attrs["email"]}]

      [_, ^second_id, secret] =
        Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", sent.text_body)

      assert [token] = sign_up_codes(attrs["email"])
      assert token.id == second_id

      assert token.metadata == %{
               "account_name" => attrs["account_name"],
               "full_name" => "Ada Lovelace"
             }

      assert Auth.verify_magic_link(first.token_id, first.secret, first.nonce) == @invalid
      assert Auth.verify_magic_link(second_id, secret, nonce) == {:ok, nil}
      assert members_with(attrs["email"]) == []
    end

    test "a code consumed by completion cannot be resent, and nothing is issued" do
      attrs = sign_up_attrs()
      code = verified_code(attrs)

      assert {:ok, %Membership{}, _raw} =
               Auth.complete_sign_up(code.token_id, browser_id(), @context)

      assert Auth.resend_email_code(code.token_id, @context) == {:error, :not_found}
      assert sign_up_codes(attrs["email"]) == []
    end

    test "a code that is gone or expired cannot be resent" do
      attrs = sign_up_attrs()
      code = request_code(attrs)
      :ok = Fixtures.Auth.backdate_token_inserted_at!(code.token_id, minutes_ago(16))

      assert Auth.resend_email_code(code.token_id, @context) == {:error, :not_found}
      assert Auth.resend_email_code(Ecto.UUID.generate(), @context) == {:error, :not_found}
      refute_received {:email, _}
    end
  end

  describe "verify_magic_link/4 — sign-up" do
    test "both halves are required, five misses spend the code and an aged code is refused — none creates anything" do
      attrs = sign_up_attrs()
      accounts_before = account_count()
      code = request_code(attrs)

      # A wrong half of either kind spends an attempt and proves nothing.
      assert Auth.verify_magic_link(code.token_id, code.secret, "another-browser") == @invalid
      assert Auth.verify_magic_link(code.token_id, "ZZZZZZ", code.nonce) == @invalid

      for _ <- 1..3,
          do: assert(Auth.verify_magic_link(code.token_id, "ZZZZZZ", code.nonce) == @invalid)

      # The fifth miss spent the code: the right halves no longer verify it.
      assert Repo.get!(UserToken, code.token_id).remaining_attempts == 0
      assert Auth.verify_magic_link(code.token_id, code.secret, code.nonce) == @invalid
      assert Auth.complete_sign_up(code.token_id, browser_id(), @context) == @invalid

      # A code older than its 15-minute window is refused with the right halves.
      fresh = request_code(attrs)
      :ok = Fixtures.Auth.backdate_token_inserted_at!(fresh.token_id, minutes_ago(16))
      assert Auth.verify_magic_link(fresh.token_id, fresh.secret, fresh.nonce) == @invalid
      assert Auth.complete_sign_up(fresh.token_id, browser_id(), @context) == @invalid

      assert members_with(attrs["email"]) == []
      assert account_count() == accounts_before
    end
  end

  describe "complete_sign_up/3" do
    test "creates the workspace, its verified owner, the policy and the session from the proved code, consuming it" do
      attrs = sign_up_attrs()
      code = verified_code(attrs)
      browser = browser_id()
      context = %RequestContext{ip_address: "203.0.113.5", request_id: "req-sign-up"}

      assert {:ok, %Membership{account: %Account{} = account} = owner, raw} =
               Auth.complete_sign_up(code.token_id, browser, context)

      assert account.name == attrs["account_name"]
      assert account.slug =~ ~r/^analytical-engines-\d+$/
      refute account.settings.require_mfa
      refute account.settings.require_sso

      assert owner.account_id == account.id
      assert owner.role == :owner
      assert owner.email == attrs["email"]
      assert owner.display_name == "Ada Lovelace"
      assert %DateTime{} = owner.email_verified_at
      assert is_nil(owner.invitation_token_digest)
      assert %DateTime{} = Repo.reload!(owner).last_active_at
      assert [%Membership{id: owner_id}] = members_with(attrs["email"])
      assert owner_id == owner.id
      assert Repo.get_by!(Emisar.Policies.Policy, account_id: account.id)

      assert {:ok, %UserToken{} = session} = Auth.fetch_session_by_token(raw, account.id)
      assert session.membership_id == owner.id
      assert session.auth_method == :magic_link
      assert session.browser_digest == Crypto.hash(browser)
      assert session.metadata["ip_address"] == "203.0.113.5"
      assert is_nil(session.mfa_verified_at)

      # The proved code is spent with the creation.
      refute Repo.get(UserToken, code.token_id)
      assert sign_up_codes(attrs["email"]) == []

      event_types =
        Audit.Event.Query.all()
        |> Audit.Event.Query.by_account_id(account.id)
        |> Repo.all()
        |> Enum.map(& &1.event_type)
        |> Enum.sort()

      assert event_types == ["account.created", "user.signed_in", "user.signed_up"]
    end

    test "a double submit creates one workspace: the consumed code fails closed" do
      attrs = sign_up_attrs()
      accounts_before = account_count()
      code = verified_code(attrs)

      assert {:ok, %Membership{} = owner, _raw} =
               Auth.complete_sign_up(code.token_id, browser_id(), @context)

      assert Auth.complete_sign_up(code.token_id, browser_id(), @context) == @invalid

      assert [%Membership{id: owner_id}] = members_with(attrs["email"])
      assert owner_id == owner.id
      assert account_count() == accounts_before + 1
    end

    test "an unverified, unknown, malformed or stale-verified code mints nothing" do
      attrs = sign_up_attrs()
      accounts_before = account_count()

      pending = request_code(attrs)
      assert Auth.complete_sign_up(pending.token_id, browser_id(), @context) == @invalid
      assert Auth.complete_sign_up(Ecto.UUID.generate(), browser_id(), @context) == @invalid
      assert Auth.complete_sign_up("not-a-uuid", browser_id(), @context) == @invalid

      # Verified more than ten minutes ago: the factor has lapsed.
      verified = verified_code(attrs)
      token = Repo.get!(UserToken, verified.token_id)

      stale_metadata =
        Map.put(token.metadata, "verified_at", DateTime.to_iso8601(minutes_ago(11)))

      {1, _} = UserToken.Query.by_id(token.id) |> Repo.update_all(set: [metadata: stale_metadata])
      assert Auth.complete_sign_up(verified.token_id, browser_id(), @context) == @invalid

      assert members_with(attrs["email"]) == []
      assert account_count() == accounts_before
      assert UserToken.Query.by_context("session") |> Repo.all() == []
    end

    test "a workspace name whose slug is taken gets the next free one" do
      name = "Acme Robotics #{System.unique_integer([:positive])}"
      taken = Accounts.suggest_unique_slug(name)
      Fixtures.Accounts.create_account(name: name, slug: taken)
      code = verified_code(sign_up_attrs(account_name: name))

      assert {:ok, %Membership{account: account}, _raw} =
               Auth.complete_sign_up(code.token_id, browser_id(), @context)

      assert account.name == name
      assert account.slug == "#{taken}-1"
    end
  end

  describe "validate_sign_up/1" do
    test "returns the trimmed submission; a blank name is no name" do
      assert {:ok, %SignUpInput{} = sign_up} =
               Accounts.validate_sign_up(%{
                 "email" => "  Owner@Example.test ",
                 "full_name" => "   ",
                 "account_name" => "  Acme  "
               })

      assert sign_up.email == "Owner@Example.test"
      assert sign_up.account_name == "Acme"
      assert is_nil(sign_up.full_name)
    end

    test "judges the derived slug's shape without reading which slugs are taken" do
      # The sign-up form submits this unauthenticated, on every save.
      test_pid = self()
      handler = {__MODULE__, test_pid, make_ref()}

      :ok =
        :telemetry.attach(
          handler,
          [:emisar, :repo, :query],
          fn _event, _measurements, metadata, _config ->
            if self() == test_pid, do: send(test_pid, {:sign_up_query, metadata.query})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, _sign_up} =
               Accounts.validate_sign_up(%{
                 "email" => "owner@example.test",
                 "account_name" => "Acme"
               })

      refute_received {:sign_up_query, _query}
    end

    test "refuses a missing address or workspace name, and a name whose slug the workspace would refuse" do
      assert {:error, changeset} = Accounts.validate_sign_up(%{})
      assert %{email: [_ | _], account_name: [_ | _]} = errors_on(changeset)

      assert {:error, changeset} =
               Accounts.validate_sign_up(%{
                 "email" => "owner@example.test",
                 "account_name" => String.duplicate("x", 300)
               })

      assert %{account_name: [_ | _]} = errors_on(changeset)
      refute Map.has_key?(errors_on(changeset), :slug)
    end
  end

  describe "change_sign_up/1" do
    test "casts the form fields without checking the slug or writing anything" do
      assert %Ecto.Changeset{data: %SignUpInput{}, action: nil} =
               changeset =
               Accounts.change_sign_up(%{"email" => " a@b.test ", "account_name" => "Acme"})

      assert changeset.changes == %{email: "a@b.test", account_name: "Acme"}
      assert %Ecto.Changeset{valid?: false} = Accounts.change_sign_up(%{})
      assert UserToken.Query.by_context("sign_up") |> Repo.all() == []
    end
  end

  describe "put_sign_up_account/2" do
    test "composes the workspace, its verified owner, the default policy and both audit rows into the caller's transaction" do
      email = Fixtures.Random.unique_email()
      name = "Composed Workspace #{System.unique_integer([:positive])}"
      expected_slug = Accounts.suggest_unique_slug(name)

      assert {:ok, %{account: account, membership: owner, policy: policy}} =
               Ecto.Multi.new()
               |> Accounts.put_sign_up_account(%{
                 email: email,
                 full_name: "Ada",
                 account_name: name
               })
               |> Repo.commit_multi()

      assert account.name == name
      assert account.slug == expected_slug
      assert owner.account_id == account.id
      assert owner.role == :owner
      assert owner.email == email
      assert owner.display_name == "Ada"
      assert %DateTime{} = owner.email_verified_at
      assert policy.account_id == account.id

      event_types =
        Audit.Event.Query.all()
        |> Audit.Event.Query.by_account_id(account.id)
        |> Repo.all()
        |> Enum.map(&{&1.event_type, &1.actor_id})
        |> Enum.sort()

      assert event_types == [{"account.created", owner.id}, {"user.signed_up", owner.id}]
    end

    test "an address that is not one fails the whole transaction" do
      accounts_before = account_count()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Ecto.Multi.new()
               |> Accounts.put_sign_up_account(%{
                 email: "not-an-address",
                 full_name: nil,
                 account_name: "Acme #{System.unique_integer([:positive])}"
               })
               |> Repo.commit_multi()

      assert %{email: [_ | _]} = errors_on(changeset)
      assert account_count() == accounts_before
    end
  end
end
