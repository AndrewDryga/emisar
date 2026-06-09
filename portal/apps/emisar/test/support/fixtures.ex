defmodule Emisar.Fixtures do
  @moduledoc """
  Test fixtures. Each helper builds (and persists) the minimal valid
  record for its schema, with sensible defaults that can be overridden
  via the `attrs` map.

  All helpers generate unique identifiers (emails, slugs, names, etc.)
  so tests using `async: true` never collide.
  """

  alias Emisar.{Accounts, Runners, ApiKeys, Policies, Repo}
  alias Emisar.Accounts.{Membership, User}
  alias Emisar.Auth.Subject
  alias Emisar.Runners.Runner

  @doc """
  Builds a `%Subject{}` for an account-scoped test caller. Looks up
  the user's membership in the account; defaults to `:owner` if the
  user isn't a member yet. Use this anywhere a test needs to call a
  Subject-gated context function.

      account = account_fixture()
      user = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user.id)
      subject = subject_for(user, account)
  """
  def subject_for(%User{} = user, account, opts \\ []) do
    role = opts[:role] || :owner
    context = opts[:context] || %{}

    membership =
      case Accounts.fetch_membership_by_account_and_user(account.id, user.id) do
        {:ok, m} ->
          m

        {:error, :not_found} ->
          %Membership{role: Atom.to_string(role), user_id: user.id, account_id: account.id}
      end

    Subject.for_user(user, account, membership, context)
  end

  @doc "Subject for a fresh user + account pair as the account owner."
  def owner_subject_fixture(account_attrs \\ %{}) do
    user = user_fixture()

    base = %{
      name: unique_account_name(),
      slug: unique_slug(),
      plan: "free"
    }

    {:ok, account} =
      Accounts.create_account_with_owner(Map.merge(base, Map.new(account_attrs)), user)

    subject = subject_for(user, account, role: :owner)
    {user, account, subject}
  end

  # -- Random helpers ---------------------------------------------------

  defp unique_int, do: System.unique_integer([:positive])

  defp unique_email, do: "user-#{unique_int()}@example.test"
  defp unique_slug, do: "acct-#{unique_int()}"
  defp unique_account_name, do: "Acct #{unique_int()}"
  defp unique_runner_name, do: "runner-#{unique_int()}"

  # -- User -------------------------------------------------------------

  @doc "Persists a user. Defaults to confirmed with a known password."
  def user_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    password = attrs[:password] || "password-with-12-chars"
    confirmed? = Map.get(attrs, :confirmed?, true)

    cast_attrs =
      %{email: unique_email(), full_name: "Test User", password: password}
      |> Map.merge(attrs)
      |> Map.drop([:confirmed?])

    {:ok, user} =
      %User{}
      |> User.Changeset.registration(cast_attrs)
      |> Repo.insert()

    if confirmed? do
      {:ok, user} = Accounts.confirm_user(user)
      user
    else
      user
    end
  end

  # -- Account ----------------------------------------------------------

  @doc "Persists an account. Defaults to plan: \"free\"."
  def account_fixture(attrs \\ %{}) do
    base = %{
      name: unique_account_name(),
      slug: unique_slug(),
      plan: "free"
    }

    {:ok, account} = Accounts.create_account(Map.merge(base, Map.new(attrs)))
    account
  end

  # -- Membership -------------------------------------------------------

  @doc """
  Creates a membership. Caller supplies `:account_id` and `:user_id` (or
  the helper will create both as defaults).
  """
  def membership_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)

    account_id =
      attrs[:account_id] || account_fixture().id

    user_id =
      attrs[:user_id] || user_fixture().id

    params =
      %{
        account_id: account_id,
        user_id: user_id,
        role: attrs[:role] || "operator"
      }
      |> Map.merge(Map.take(attrs, [:invited_by_id, :invitation_token]))

    {:ok, m} = params |> Membership.Changeset.create() |> Repo.insert()
    m
  end

  @doc """
  Test-only role override. Production code MUST go through
  `Accounts.update_membership_role/3` with a `%Subject{}`. This bypasses
  the last-owner / self-promotion / role-hierarchy guards, which exist
  to protect humans — fine to ignore in fixtures that rig a state
  directly.
  """
  def force_membership_role(%Accounts.Membership{} = m, role) when is_binary(role) do
    {:ok, updated} =
      m
      |> Accounts.Membership.Changeset.update(%{role: role})
      |> Emisar.Repo.update()

    updated
  end

  # -- Runner ------------------------------------------------------------

  @doc """
  Persists a runner in `connected` status by default. Caller supplies
  `:account_id` (or the helper makes a fresh account).
  """
  def runner_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)

    account_id =
      attrs[:account_id] || account_fixture().id

    params = %{
      account_id: account_id,
      name: attrs[:name] || unique_runner_name(),
      external_id: attrs[:external_id] || Ecto.UUID.generate(),
      group: attrs[:group] || "default",
      hostname: attrs[:hostname] || "host-#{unique_int()}",
      labels: attrs[:labels] || %{},
      runner_version: attrs[:runner_version] || "0.1.0"
    }

    {:ok, runner} =
      params
      |> Runner.Changeset.register()
      |> Repo.insert()

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
  Inserts a catalog action row for a runner. Mirrors what
  `Catalog.observe_state` would do when a runner advertises this action.
  Defaults to `action_id: "linux.uptime"`, `risk: "low"`, `kind: "exec"`.
  """
  def action_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    runner = attrs[:runner] || raise ":runner is required"

    params = %{
      account_id: runner.account_id,
      runner_id: runner.id,
      action_id: attrs[:action_id] || "linux.uptime",
      pack_id: attrs[:pack_id] || "linux-core",
      title: attrs[:title] || "Uptime",
      kind: attrs[:kind] || "exec",
      risk: attrs[:risk] || "low",
      description: attrs[:description] || "Reports uptime + load.",
      side_effects: attrs[:side_effects] || ["reads /proc"],
      args_schema: attrs[:args_schema] || %{"args" => []},
      limits: attrs[:limits] || %{},
      output: attrs[:output] || %{},
      examples: attrs[:examples] || [],
      first_seen_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      last_seen_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    {:ok, action} =
      Emisar.Catalog.RunnerAction.Changeset.upsert(params)
      |> Repo.insert()

    action
  end

  # -- Auth key ---------------------------------------------------------

  @doc """
  Creates a bootstrap auth key. Returns `{raw, key}` so callers can
  test both the raw secret + the persisted struct.
  """
  def auth_key_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    account_id = attrs[:account_id] || account_fixture().id
    user_id = attrs[:created_by_id] || user_fixture().id

    create_attrs =
      attrs
      |> Map.take([:description, :group, :reusable, :max_uses, :expires_at])

    account = Emisar.Accounts.fetch_account_by_id!(account_id)
    user = Emisar.Accounts.fetch_user_by_id!(user_id)
    subject = subject_for(user, account, role: :owner)
    {:ok, raw, key} = Runners.create_auth_key(create_attrs, subject)
    {raw, key}
  end

  # -- API key ----------------------------------------------------------

  @doc """
  Creates an API key. Returns `{raw, key}`.
  """
  def api_key_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    account_id = attrs[:account_id] || account_fixture().id
    user_id = attrs[:created_by_id] || user_fixture().id

    create_attrs =
      %{
        name: attrs[:name] || "key-#{unique_int()}",
        description: attrs[:description],
        scopes: attrs[:scopes] || ["actions:read", "actions:execute"],
        runner_filter: attrs[:runner_filter] || [],
        expires_at: attrs[:expires_at]
      }

    account = Emisar.Accounts.fetch_account_by_id!(account_id)
    user = Emisar.Accounts.fetch_user_by_id!(user_id)
    subject = subject_for(user, account, role: :owner)
    {:ok, raw, key} = ApiKeys.create_key(create_attrs, subject)
    {raw, key}
  end

  # -- Policy -----------------------------------------------------------

  @doc """
  Seeds or replaces the account's policy. Defaults to "allow
  everything". Override `:rules` to test other shapes.

  Since there's exactly one policy per account, this either inserts on
  first call OR updates the existing row's rules — never creates a
  second row.
  """
  def policy_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    account_id = attrs[:account_id] || account_fixture().id
    user_id = attrs[:created_by_id] || user_fixture().id

    rules =
      attrs[:rules] ||
        %{
          "schema_version" => 2,
          "defaults" => %{
            "low" => "allow",
            "medium" => "allow",
            "high" => "allow",
            "critical" => "allow"
          },
          "overrides" => []
        }

    case Policies.peek_policy_for_account(account_id) do
      nil ->
        {:ok, _} = Policies.seed_policy(account_id, user_id, rules)
        Policies.peek_policy_for_account(account_id)

      policy ->
        {:ok, updated} =
          Repo.update(
            Emisar.Policies.Policy.Changeset.update(policy, %{
              rules: rules,
              updated_by_id: user_id
            })
          )

        updated
    end
  end
end
