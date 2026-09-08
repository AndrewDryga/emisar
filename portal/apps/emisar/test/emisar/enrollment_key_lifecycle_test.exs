defmodule Emisar.EnrollmentKeyLifecycleTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Audit, Fixtures, Repo, RequestContext, Runners}
  alias Emisar.Runners.EnrollmentKey
  alias Emisar.Runners.Jobs.InstallKeyRetention

  describe "enrollment_key_status/1" do
    test "reports expiry, revocation and exhausted-use precedence" do
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      future = DateTime.add(DateTime.utc_now(), 60, :second)

      for {attrs, expected} <- [
            {%{}, :active},
            {%{expires_at: future}, :active},
            {%{expires_at: past}, :expired},
            {%{revoked_at: past, expires_at: past, uses_count: 1}, :revoked},
            {%{expires_at: past, uses_count: 1}, :expired},
            {%{reusable: false, uses_count: 1}, :spent},
            {%{reusable: true, uses_count: 1, max_uses: 2}, :active},
            {%{reusable: true, uses_count: 2, max_uses: 2}, :spent}
          ] do
        assert Runners.enrollment_key_status(struct(EnrollmentKey, attrs)) == expected
      end
    end
  end

  test "console keys have a 24-hour lifetime; manual keys retain their chosen expiry" do
    account = Fixtures.Accounts.create_account()
    user = Fixtures.Users.create_user()

    membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "owner"
      )

    subject = Fixtures.Subjects.membership_subject(membership)

    assert {:ok, raw, key} = Runners.mint_install_key(subject)
    assert DateTime.diff(key.expires_at, key.auto_generated_at, :second) == 86_400
    assert %EnrollmentKey{} = Runners.peek_enrollment_key_by_secret(raw)

    assert {:ok, _raw, manual} = Runners.create_enrollment_key(%{reusable: true}, subject)
    assert is_nil(manual.expires_at)

    expiry = DateTime.add(DateTime.utc_now(), 7 * 86_400, :second)
    assert {:ok, _raw, manual} = Runners.create_enrollment_key(%{expires_at: expiry}, subject)
    assert manual.expires_at == expiry
  end

  test "expired console keys cannot enroll, even before daily cleanup" do
    expiry = DateTime.add(DateTime.utc_now(), -1, :second)
    {raw, key} = Fixtures.Runners.create_install_key(expires_at: expiry)

    assert {:error, :enrollment_key_invalid} =
             Runners.register_via_enrollment_key(raw, %{external_id: "expired-install"})

    refute EnrollmentKey.usable?(key)
    assert Runners.enrollment_key_status(key) == :expired
    assert Repo.reload!(key).uses_count == 0
  end

  test "Active excludes expired, revoked, deleted, spent, and exhausted reusable keys" do
    account = Fixtures.Accounts.create_account()
    {_, active} = Fixtures.Runners.create_enrollment_key(account_id: account.id)

    {_, reusable} =
      Fixtures.Runners.create_enrollment_key(account_id: account.id, reusable: true, max_uses: 2)

    Fixtures.Runners.spend_enrollment_key(reusable)

    past = DateTime.add(DateTime.utc_now(), -60, :second)
    Fixtures.Runners.create_enrollment_key(account_id: account.id, expires_at: past)

    for state <- [[revoked_at: past], [deleted_at: past], [uses_count: 1, last_used_at: past]] do
      {_, key} = Fixtures.Runners.create_enrollment_key(account_id: account.id)
      Fixtures.Runners.set_enrollment_key_state(key, state)
    end

    {_, exhausted} =
      Fixtures.Runners.create_enrollment_key(account_id: account.id, reusable: true, max_uses: 1)

    Fixtures.Runners.spend_enrollment_key(exhausted)

    subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)
    assert {:ok, keys, _} = Runners.list_enrollment_keys(subject, filter: [status: ["active"]])
    assert MapSet.new(keys, & &1.id) == MapSet.new([active.id, reusable.id])

    assert {:ok, keys, _} =
             Runners.list_enrollment_keys(subject, filter: [status: ["active", "revoked"]])

    assert length(keys) == 3
    assert Enum.all?(keys, &(Runners.enrollment_key_status(&1) in [:active, :revoked]))
  end

  test "source filtering preserves account isolation and console origin after enrollment" do
    account = Fixtures.Accounts.create_account()
    {raw, console} = Fixtures.Runners.create_install_key(account_id: account.id)
    {_, manual} = Fixtures.Runners.create_enrollment_key(account_id: account.id)
    Fixtures.Runners.create_install_key()
    subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)

    assert {:ok, [key], _} = Runners.list_enrollment_keys(subject, filter: [source: ["console"]])
    assert key.id == console.id
    assert {:ok, [key], _} = Runners.list_enrollment_keys(subject, filter: [source: ["manual"]])
    assert key.id == manual.id

    assert {:ok, _runner, _token, _raw_token} =
             Runners.register_via_enrollment_key(raw, %{
               external_id: "installed",
               hostname: "installed"
             })

    assert {:ok, [key], _} = Runners.list_enrollment_keys(subject, filter: [source: ["console"]])
    assert key.auto_generated_at == console.auto_generated_at
    assert Runners.enrollment_key_status(key) == :spent
    refute EnrollmentKey.auto_unused?(key)

    viewer = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :viewer)

    assert {:error, :unauthorized} =
             Runners.list_enrollment_keys(viewer, filter: [source: ["console"]])
  end

  describe "delete_expired_install_keys/2" do
    test "cleanup is account-scoped, bounded, idempotent, and leaves used/manual/fresh keys" do
      account = Fixtures.Accounts.create_account()
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      for _ <- 1..3,
          do: Fixtures.Runners.create_install_key(account_id: account.id, expires_at: past)

      {_, fresh} = Fixtures.Runners.create_install_key(account_id: account.id)

      {_, used} =
        Fixtures.Runners.create_install_key(
          account_id: account.id,
          expires_at: past,
          last_used_at: past,
          uses_count: 1
        )

      {_, manual} =
        Fixtures.Runners.create_enrollment_key(account_id: account.id, expires_at: past)

      {_, foreign} = Fixtures.Runners.create_install_key(expires_at: past)

      assert {:ok, 3} = Runners.delete_expired_install_keys(account.id, batch_size: 1)
      assert {:ok, 0} = Runners.delete_expired_install_keys(account.id, batch_size: 1)
      for key <- [fresh, used, manual, foreign], do: assert(Repo.reload!(key))
    end
  end

  test "daily job visits every account and safely repeats" do
    assert %{start: {_executor, :start_link, [{InstallKeyRetention, interval, _config}]}} =
             InstallKeyRetention.child_spec([])

    assert interval == :timer.hours(24)

    past = DateTime.add(DateTime.utc_now(), -60, :second)
    {_, first} = Fixtures.Runners.create_install_key(expires_at: past)
    {_, second} = Fixtures.Runners.create_install_key(expires_at: past)

    assert :ok = InstallKeyRetention.execute(limit: 1, batch_size: 1)
    assert :ok = InstallKeyRetention.execute(limit: 1, batch_size: 1)
    assert is_nil(Repo.reload(first))
    assert is_nil(Repo.reload(second))
  end

  test "ring eviction retains a used console key after its origin marker is preserved" do
    account = Fixtures.Accounts.create_account()
    user = Fixtures.Users.create_user()
    past = DateTime.add(DateTime.utc_now(), -120, :second)

    {_, used} =
      Fixtures.Runners.create_install_key(
        account_id: account.id,
        created_by_id: user.id,
        auto_generated_at: past,
        last_used_at: past,
        uses_count: 1
      )

    subject = Fixtures.Subjects.subject_for(user, account)

    for _ <- 1..3 do
      assert {:ok, _raw, _key} =
               Runners.mint_install_key(subject, ring_cap: 1, eviction_grace_seconds: 0)
    end

    assert Repo.reload!(used).auto_generated_at == past
  end

  test "creation receipts snapshot expiry and usage limits, including explicit absence" do
    membership = Fixtures.Memberships.create_membership(role: "owner")
    subject = Fixtures.Subjects.membership_subject(membership)
    expires_at = DateTime.add(DateTime.utc_now(), 86_400)

    for attrs <- [
          %{reusable: true, max_uses: 3, expires_at: expires_at},
          %{reusable: true},
          %{reusable: false}
        ] do
      assert {:ok, raw, key} = Runners.create_enrollment_key(attrs, subject)
      event = Enum.find(Repo.all(Audit.Event), &(&1.target_id == key.id))
      assert event.account_id == subject.account.id
      assert event.actor_id == subject.actor.id
      assert event.payload["reusable"] == key.reusable
      assert Map.fetch!(event.payload, "max_uses") == key.max_uses
      expected_expiry = if key.expires_at, do: DateTime.to_iso8601(key.expires_at)
      assert Map.fetch!(event.payload, "expires_at") == expected_expiry
      refute Jason.encode!(event.payload) =~ raw
    end
  end

  test "a setup key's first registration records its runner and ignores a stale-key retry" do
    {_raw, key} = Fixtures.Runners.create_install_key()
    attrs = %{external_id: "receipt-runner", hostname: "receipt-host", group: "database"}
    context = %RequestContext{ip_address: "203.0.113.9", request_id: "register-receipt"}

    assert {:ok, runner, _token, _raw_token} =
             Runners.register_via_enrollment_key(key, attrs, context)

    assert {:ok, retry_runner, _token, _raw_token} =
             Runners.register_via_enrollment_key(key, attrs, context)

    assert retry_runner.id == runner.id
    assert [event] = bound_receipts()
    assert event.account_id == key.account_id
    assert event.target_id == key.id
    assert event.ip_address == context.ip_address
    assert event.request_id == context.request_id
    assert event.payload["auto"]
    assert event.payload["runner_id"] == runner.id
    assert event.payload["runner_name"] == runner.name
    assert event.payload["hostname"] == runner.hostname
    assert event.payload["group"] == "database"
    Fixtures.Runners.move_to_group(runner, "web")
    assert Repo.reload!(event).payload["group"] == "database"
  end

  test "parallel registration retries produce one binding receipt" do
    {_raw, key} = Fixtures.Runners.create_install_key()
    attrs = %{external_id: "parallel-receipt", hostname: "parallel-receipt"}

    results =
      1..4
      |> Task.async_stream(fn _ -> Runners.register_via_enrollment_key(key, attrs) end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, %Runners.Runner{}, %Runners.Token{}, _raw}, &1))
    assert [_event] = bound_receipts()
    assert Repo.reload!(key).uses_count == 1
  end

  test "a failed registration does not consume or audit the setup key" do
    {_raw, key} = Fixtures.Runners.create_install_key()

    Fixtures.Runners.create_runner(
      account_id: key.account_id,
      name: "occupied",
      external_id: "other-runner",
      connected?: false
    )

    attrs = %{external_id: "occupied", hostname: "occupied"}

    assert Runners.register_via_enrollment_key(key, attrs) ==
             {:error, :runner_name_taken, "occupied"}

    assert bound_receipts() == []
    assert Repo.reload!(key).uses_count == 0
  end

  defp bound_receipts do
    Enum.filter(Repo.all(Audit.Event), &(&1.event_type == "enrollment_key.bound"))
  end
end
