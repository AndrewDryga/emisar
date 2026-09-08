defmodule Emisar.RunnerCredentialRotationTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Audit, Fixtures, Repo, RequestContext, Runners}

  describe "request_credential_rotation/2" do
    test "an offline runner keeps an audited, idempotent request until a new credential connects" do
      {user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      {raw, token} = Fixtures.Runners.create_token(runner)
      runner = Fixtures.Runners.set_connection_credential(runner, token)
      Runners.subscribe_account_credentials(account.id)

      assert Runners.refresh_runner_token(raw) == {:error, :not_due}
      assert {:ok, requested} = Runners.request_credential_rotation(runner, subject)
      assert_receive {:runner_credentials_changed, _}
      assert Runners.credential_facts(requested).pending?
      assert Repo.reload!(token).expires_at == token.expires_at
      assert {:ok, repeated} = Runners.request_credential_rotation(runner, subject)
      assert_receive {:runner_credentials_changed, _}

      assert repeated.credential_rotation_requested_at ==
               requested.credential_rotation_requested_at

      events =
        Enum.filter(
          Repo.all(Audit.Event),
          &(&1.event_type == "runner.credential_rotation_requested")
        )

      assert [event] = events
      assert event.actor_id == user.id

      assert {:ok, successor_raw, _refresh_after} = Runners.refresh_runner_token(raw)
      assert_receive {:runner_credentials_changed, _}
      assert replacement_receipts() == []
      assert {:ok, successor, _runner} = Runners.verify_runner_token(successor_raw)
      assert successor.id != token.id
      assert successor.replaces_id == token.id
      assert Runners.refresh_runner_token(successor_raw) == {:error, :not_due}
      assert [receipt] = replacement_receipts()
      assert receipt.payload["token_id"] == successor.id
      assert receipt.payload["replaces_id"] == token.id

      assert {:ok, before_adoption} =
               Runners.fetch_runner_by_id(runner.id, subject, preload: [:connection_token])

      assert before_adoption.connection_token.id == token.id
      assert Runners.credential_facts(before_adoption).pending?

      assert {:ok, connected} = Runners.connect_runner(runner, successor.id)
      assert_receive {:runner_credentials_changed, _}
      assert connected.connection_token_id == successor.id

      assert {:ok, adopted} =
               Runners.fetch_runner_by_id(runner.id, subject, preload: [:connection_token])

      refute Runners.credential_facts(adopted).pending?
      assert Runners.credential_facts(adopted).expires_at == successor.expires_at
    end

    test "a failed handoff can retry the old token without extending its grace" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      {raw, token} = Fixtures.Runners.create_token(runner)
      runner = Fixtures.Runners.set_connection_credential(runner, token)
      assert {:ok, _requested} = Runners.request_credential_rotation(runner, subject)
      assert {:ok, _unused, _} = Runners.refresh_runner_token(raw)
      expires_at = Repo.reload!(token).expires_at
      assert {:ok, _retried, _} = Runners.refresh_runner_token(raw)
      assert Repo.reload!(token).expires_at == expires_at
    end

    test "unsupported or expired credentials cannot be requested" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      {raw, token} = Fixtures.Runners.create_token(runner)
      unsupported = Fixtures.Runners.set_connection_credential(runner, token, false)

      assert Runners.request_credential_rotation(unsupported, subject) ==
               {:error, :rotation_not_supported}

      expired = Fixtures.Runners.expire_token(token)
      runner = Fixtures.Runners.set_connection_credential(runner, expired)
      assert Runners.request_credential_rotation(runner, subject) == {:error, :token_expired}
      assert Runners.refresh_runner_token(raw) == {:error, :token_expired}
      assert Repo.reload!(runner).credential_rotation_requested_at == nil
    end

    test "rotation requires permission, account ownership, and current runner access" do
      {user, account, _owner} = Fixtures.Subjects.owner_subject()
      membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
      membership = Fixtures.Memberships.force_role(membership, "admin")
      admin = Fixtures.Subjects.membership_subject(membership)

      runner =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          group: "database",
          connected?: false
        )

      {_raw, token} = Fixtures.Runners.create_token(runner)
      runner = Fixtures.Runners.set_connection_credential(runner, token)
      viewer = Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer")

      assert Runners.request_credential_rotation(
               runner,
               Fixtures.Subjects.membership_subject(viewer)
             ) ==
               {:error, :unauthorized}

      foreign = Fixtures.Memberships.create_membership(role: "owner")

      assert Runners.request_credential_rotation(
               runner,
               Fixtures.Subjects.membership_subject(foreign)
             ) ==
               {:error, :not_found}

      {:ok, web_only} = Accounts.RunnerAccess.restricted(["web"], [])
      Fixtures.Memberships.force_runner_access(membership, web_only)
      assert Runners.request_credential_rotation(runner, admin) == {:error, :not_found}

      Fixtures.Memberships.force_role(membership, "viewer")
      assert Runners.request_credential_rotation(runner, admin) == {:error, :unauthorized}
      assert Repo.reload!(runner).credential_rotation_requested_at == nil
    end
  end

  describe "replacement-key authentication receipts" do
    test "first use is audited once without ending the previous key's grace" do
      runner = Fixtures.Runners.create_runner(connected?: false)
      {old_raw, previous} = Fixtures.Runners.create_token(runner)
      Fixtures.Runners.strip_token_expiry(previous)

      assert {:ok, raw, _refresh_after} = Runners.refresh_runner_token(old_raw)
      assert replacement_receipts() == []
      grace_end = Repo.reload!(previous).expires_at
      context = %RequestContext{ip_address: "203.0.113.8", request_id: "runner-key-use"}

      assert {:ok, replacement, authenticated_runner} = Runners.verify_runner_token(raw, context)
      assert authenticated_runner.id == runner.id
      assert {:ok, _replacement, _runner} = Runners.verify_runner_token(raw, context)
      assert {:ok, _previous, _runner} = Runners.verify_runner_token(old_raw)

      assert [event] = replacement_receipts()
      assert event.account_id == runner.account_id
      assert event.actor_kind == "runner"
      assert event.actor_id == runner.id
      assert event.target_id == runner.id
      assert event.ip_address == context.ip_address
      assert event.request_id == context.request_id
      assert event.payload["token_id"] == replacement.id
      assert event.payload["token_prefix"] == replacement.token_prefix
      assert event.payload["replaces_id"] == previous.id
      assert event.payload["previous_token_prefix"] == previous.token_prefix
      assert event.payload["expires_at"] == DateTime.to_iso8601(replacement.expires_at)
      refute Map.has_key?(event.payload, "token_hash")
      refute Jason.encode!(event.payload) =~ raw
      refute Jason.encode!(event.payload) =~ old_raw
      assert Repo.reload!(previous).expires_at == grace_end
      refute Runners.online?(runner.account_id, runner.id)
    end

    test "parallel first authentication produces one durable receipt" do
      runner = Fixtures.Runners.create_runner(connected?: false)
      {_old_raw, previous} = Fixtures.Runners.create_token(runner)
      {raw, replacement} = Fixtures.Runners.create_token(runner, replaces_id: previous.id)

      results =
        1..4
        |> Task.async_stream(fn _ -> Runners.verify_runner_token(raw) end)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, %Runners.Token{}, %Runners.Runner{}}, &1))
      assert [event] = replacement_receipts()
      assert event.payload["token_id"] == replacement.id
      assert Repo.reload!(replacement).last_used_at
    end

    test "an audit failure rolls back first use so a valid retry records the receipt" do
      runner = Fixtures.Runners.create_runner(connected?: false)
      {_old_raw, previous} = Fixtures.Runners.create_token(runner)
      {raw, replacement} = Fixtures.Runners.create_token(runner, replaces_id: previous.id)
      invalid_context = %RequestContext{ip_address: %{invalid: true}}

      assert Runners.verify_runner_token(raw, invalid_context) ==
               {:error, :authentication_unavailable}

      assert Repo.reload!(replacement).last_used_at == nil
      assert replacement_receipts() == []
      assert {:ok, _replacement, _runner} = Runners.verify_runner_token(raw)
      assert [_event] = replacement_receipts()
    end

    test "initial keys and forged or expired replacements produce no receipt" do
      runner = Fixtures.Runners.create_runner(connected?: false)
      {initial_raw, initial} = Fixtures.Runners.create_token(runner)
      assert {:ok, _initial, _runner} = Runners.verify_runner_token(initial_raw)
      {raw, replacement} = Fixtures.Runners.create_token(runner, replaces_id: initial.id)

      assert Runners.verify_runner_token(raw <> "forged") == {:error, :token_invalid}
      assert Repo.reload!(replacement).last_used_at == nil
      Fixtures.Runners.expire_token(replacement)
      assert Runners.verify_runner_token(raw) == {:error, :token_expired}
      assert Repo.reload!(replacement).last_used_at == nil
      assert replacement_receipts() == []
    end

    test "disabled runners and accounts cannot claim replacement use" do
      runner = Fixtures.Runners.create_runner(connected?: false)
      {_old_raw, previous} = Fixtures.Runners.create_token(runner)
      {raw, replacement} = Fixtures.Runners.create_token(runner, replaces_id: previous.id)
      Fixtures.Runners.disable_runner(runner)
      assert Runners.verify_runner_token(raw) == {:error, :runner_disabled}
      assert Repo.reload!(replacement).last_used_at == nil

      account = Fixtures.Accounts.create_account()
      other = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      {_old_raw, previous} = Fixtures.Runners.create_token(other)
      {raw, replacement} = Fixtures.Runners.create_token(other, replaces_id: previous.id)
      Fixtures.Accounts.disable_account(account)
      assert Runners.verify_runner_token(raw) == {:error, :account_disabled}
      assert Repo.reload!(replacement).last_used_at == nil
      assert replacement_receipts() == []
    end

    test "a predecessor from another runner or account cannot enter the receipt" do
      runner = Fixtures.Runners.create_runner(connected?: false)
      other = Fixtures.Runners.create_runner(account_id: runner.account_id, connected?: false)
      foreign = Fixtures.Runners.create_runner(connected?: false)

      for source_runner <- [other, foreign] do
        {_old_raw, previous} = Fixtures.Runners.create_token(source_runner)
        {raw, replacement} = Fixtures.Runners.create_token(runner, replaces_id: previous.id)
        assert Runners.verify_runner_token(raw) == {:error, :token_invalid}
        assert Repo.reload!(replacement).last_used_at == nil
      end

      assert replacement_receipts() == []
    end
  end

  describe "credential_facts/1" do
    test "unloaded credentials stay unknown and loaded facts reflect expiry and pending adoption" do
      runner = %Runners.Runner{}

      assert Runners.credential_facts(runner) ==
               %{known?: false, expires_at: nil, expired?: false, pending?: false}

      now = DateTime.utc_now()
      expires_at = DateTime.add(now, 3_600)
      token = %Runners.Token{issued_at: DateTime.add(now, -60), expires_at: expires_at}
      runner = %{runner | connection_token: token, credential_rotation_requested_at: now}

      assert Runners.credential_facts(runner) ==
               %{known?: true, expires_at: expires_at, expired?: false, pending?: true}

      replacement = %{token | issued_at: DateTime.add(now, 1)}
      refute Runners.credential_facts(%{runner | connection_token: replacement}).pending?

      expired = %{token | expires_at: DateTime.add(now, -60)}
      assert Runners.credential_facts(%{runner | connection_token: expired}).expired?
    end
  end

  describe "credential_rotation_requested?/2" do
    test "only credentials issued no later than the request remain pending" do
      requested_at = DateTime.utc_now()
      runner = %Runners.Runner{credential_rotation_requested_at: requested_at}

      assert Runners.credential_rotation_requested?(runner, DateTime.add(requested_at, -1))
      assert Runners.credential_rotation_requested?(runner, requested_at)
      refute Runners.credential_rotation_requested?(runner, DateTime.add(requested_at, 1))
      refute Runners.credential_rotation_requested?(runner, nil)
      refute Runners.credential_rotation_requested?(%Runners.Runner{}, requested_at)
    end
  end

  describe "credential_rotation_message/3" do
    test "a rotation request targets only the authenticated token prefix and is recovered on reconnect" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      {_raw, token} = Fixtures.Runners.create_token(runner)
      runner = Fixtures.Runners.set_connection_credential(runner, token)
      assert {:ok, requested} = Runners.request_credential_rotation(runner, subject)

      assert Runners.credential_rotation_message(requested, token.token_prefix, token.issued_at) ==
               %{
                 "type" => "refresh_credentials",
                 "protocol_version" => 1,
                 "token_prefix" => token.token_prefix
               }

      assert Runners.credential_rotation_message(requested, "replacement", DateTime.utc_now()) ==
               nil
    end
  end

  describe "subscribe_account_credentials/1" do
    test "capability changes notify open pages without broadcasting unchanged advertisements" do
      runner = Fixtures.Runners.create_runner(connected?: false)
      Runners.subscribe_account_credentials(runner.account_id)
      id = runner.id

      assert {:ok, supported} =
               Runners.apply_state(runner, %{"credential_rotation_supported" => true})

      assert supported.credential_rotation_supported
      assert_receive {:runner_credentials_changed, ^id}

      assert {:ok, _runner} =
               Runners.apply_state(runner, %{"credential_rotation_supported" => true})

      refute_receive {:runner_credentials_changed, ^id}

      assert {:ok, unsupported} = Runners.apply_state(runner, %{})
      refute unsupported.credential_rotation_supported
      assert_receive {:runner_credentials_changed, ^id}
    end
  end

  defp replacement_receipts do
    Enum.filter(Repo.all(Audit.Event), &(&1.event_type == "runner.credential_rotated"))
  end
end
