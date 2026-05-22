defmodule Emisar.Fixtures do
  @moduledoc """
  Test fixtures. Each helper builds (and persists) the minimal valid
  record for its schema, with sensible defaults that can be overridden
  via the `attrs` map.

  All helpers generate unique identifiers (emails, slugs, names, etc.)
  so tests using `async: true` never collide.
  """

  alias Emisar.{Accounts, Runners, ApiKeys, Policies, Repo}
  alias Emisar.Accounts.User
  alias Emisar.Runners.Runner

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
      |> User.registration_changeset(cast_attrs)
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

    {:ok, m} = Accounts.create_membership(params)
    m
  end

  # -- Runner ------------------------------------------------------------

  @doc """
  Persists an runner in `connected` status by default. Caller supplies
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
      %Runner{}
      |> Runner.registration_changeset(params)
      |> Repo.insert()

    if Map.get(attrs, :connected?, true) do
      {:ok, runner} = Runners.mark_connected(runner, %{})
      runner
    else
      runner
    end
  end

  @doc """
  Inserts a catalog action row for an runner. Mirrors what
  `Catalog.observe_state` would do when an runner advertises this action.
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
      %Emisar.Catalog.RunnerAction{}
      |> Emisar.Catalog.RunnerAction.changeset(params)
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

    {:ok, raw, key} = Runners.create_auth_key(account_id, user_id, create_attrs)
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

    {:ok, raw, key} = ApiKeys.create_key(account_id, user_id, create_attrs)
    {raw, key}
  end

  # -- Policy -----------------------------------------------------------

  @doc """
  Creates a policy. Defaults to an "allow everything" rule set, marked
  as the default policy. Override `:rules` to test other shapes.
  """
  def policy_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    account_id = attrs[:account_id] || account_fixture().id
    user_id = attrs[:created_by_id] || user_fixture().id

    create_attrs = %{
      name: attrs[:name] || "policy-#{unique_int()}",
      description: attrs[:description],
      is_default: Map.get(attrs, :is_default, true),
      rules:
        attrs[:rules] ||
          %{
            "allow" => [%{"name" => "allow-all", "action" => "*"}],
            "deny" => [],
            "require_approval" => []
          }
    }

    {:ok, policy} = Policies.create_policy(account_id, create_attrs, user_id)
    policy
  end
end
