defmodule Emisar.Fixtures.Runners do
  @moduledoc """
  Runner + auth-key test fixtures. Use via `alias Emisar.Fixtures` then
  `Fixtures.Runners.create_runner/1`.
  """

  alias Emisar.Accounts.Account
  alias Emisar.{Fixtures, Repo, Runners, Users}
  alias Emisar.Runners.Runner

  @doc """
  Persists a runner in `connected` status by default. Caller supplies
  `:account_id` (or the helper makes a fresh account).
  """
  def create_runner(attrs \\ %{}) do
    attrs = Map.new(attrs)

    account_id =
      attrs[:account_id] || Fixtures.Accounts.create_account().id

    params = %{
      account_id: account_id,
      name: attrs[:name] || Fixtures.Random.unique_runner_name(),
      external_id: attrs[:external_id] || Ecto.UUID.generate(),
      group: attrs[:group] || "default",
      hostname: attrs[:hostname] || "host-#{Fixtures.Random.unique_int()}",
      labels: attrs[:labels] || %{},
      runner_version: attrs[:runner_version] || "0.1.0",
      bootstrap_auth_key_id: attrs[:bootstrap_auth_key_id]
    }

    {:ok, runner} =
      params
      |> Runner.Changeset.register()
      |> Repo.insert()

    # `enforce_signatures` is advertised via runner_state, not registration —
    # apply it through the same changeset a real advertisement would.
    runner =
      if Map.get(attrs, :enforce_signatures) do
        {:ok, runner} =
          runner |> Runner.Changeset.apply_state(%{enforce_signatures: true}) |> Repo.update()

        runner
      else
        runner
      end

    if Map.get(attrs, :connected?, true) do
      # Tracks presence from the calling (test) process and stamps
      # last_connected_at — the runner reads "online" for the test's
      # lifetime, then auto-untracks when the process exits.
      {:ok, runner} = Runners.connect_runner(runner)
      runner
    else
      runner
    end
  end

  @doc """
  Creates a bootstrap auth key. Returns `{raw, key}` so callers can
  test both the raw secret + the persisted struct.
  """
  def create_auth_key(attrs \\ %{}) do
    attrs = Map.new(attrs)
    account_id = attrs[:account_id] || Fixtures.Accounts.create_account().id
    user_id = attrs[:created_by_id] || Fixtures.Users.create_user().id

    create_attrs =
      attrs
      |> Map.take([:description, :group, :reusable, :max_uses, :expires_at])

    account =
      Account.Query.not_deleted()
      |> Account.Query.by_id(account_id)
      |> Repo.fetch!(Account.Query)

    {:ok, user} = Users.fetch_user_by_id(user_id)
    subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
    {:ok, raw, key} = Runners.create_auth_key(create_attrs, subject)
    {raw, key}
  end

  @doc """
  Auth key persisted from a caller-supplied raw secret — the seed/dev
  bootstrap shape (`AuthKey.Changeset.create_with_secret/4`). Tests use
  it to exercise the secret→key round-trip with a known raw value.
  """
  def create_auth_key_with_secret(raw, account_id, user_id, attrs \\ %{}) do
    {:ok, key} =
      Runners.AuthKey.Changeset.create_with_secret(account_id, user_id, raw, attrs)
      |> Repo.insert()

    key
  end
end
