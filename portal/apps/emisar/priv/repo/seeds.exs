# Seeds for local dev. Run with `mix run apps/emisar/priv/repo/seeds.exs`
# or via `mix ecto.setup`. Idempotent — safe to re-run.

alias Emisar.{Accounts, Runners, Audit, Policies, Runbooks}
alias Emisar.Accounts.User

# -- Demo account + owner --------------------------------------------

demo_email = "demo@emisar.dev"

user =
  case Accounts.get_user_by_email(demo_email) do
    nil ->
      {:ok, u} =
        Accounts.register_user(%{
          full_name: "Demo User",
          email: demo_email,
          password: "Sleep-tight-1234"
        })

      {:ok, u} = Accounts.confirm_user(u)
      u

    %User{full_name: nil} = u ->
      {:ok, u} = Accounts.update_user_profile(u, %{full_name: "Demo User"})
      u

    %User{} = u ->
      u
  end

account =
  case Accounts.get_account_by_slug("demo") do
    nil ->
      {:ok, account} =
        Accounts.create_account_with_owner(
          %{name: "Demo Corp", slug: "demo", plan: "team"},
          user
        )

      account

    a ->
      a
  end

IO.puts(
  IO.ANSI.cyan() <>
    "✓ Demo account ready (slug=demo, owner=#{demo_email}, password=Sleep-tight-1234)" <>
    IO.ANSI.reset()
)

# -- Default policy ---------------------------------------------------

unless Policies.get_default_policy(account.id) do
  {:ok, _} =
    Policies.create_policy(
      account.id,
      %{
        name: "Default",
        description: "Allow low/medium-risk; high needs approval; critical blocked.",
        is_default: true,
        rules: %{
          "deny" => [%{"name" => "no-critical", "max_risk" => "critical", "risk" => "critical"}],
          "require_approval" => [%{"name" => "approve-high", "risk" => "high"}],
          "allow" => [%{"name" => "allow-low-medium", "max_risk" => "medium"}]
        }
      },
      user.id
    )

  IO.puts(IO.ANSI.cyan() <> "✓ Seeded default policy" <> IO.ANSI.reset())
end

# -- Sample runbook ---------------------------------------------------

unless Enum.find(Runbooks.list_runbooks(account.id), &(&1.slug == "cassandra-rolling-repair")) do
  {:ok, _rb} =
    Runbooks.create_runbook(account.id, user.id, %{
      name: "cassandra-rolling-repair",
      slug: "cassandra-rolling-repair",
      title: "Cassandra rolling repair",
      description:
        "Pre-flight check → run nodetool repair on each Cassandra node in turn.",
      status: "published",
      definition: %{
        "steps" => [
          %{
            "id" => "preflight",
            "action_id" => "cassandra.nodetool_status",
            "runner_selector" => %{"group" => "cassandra-us-east1"}
          },
          %{
            "id" => "assert_healthy",
            "kind" => "assert",
            "expression" => "preflight.exit_code == 0"
          },
          %{
            "id" => "repair",
            "action_id" => "cassandra.nodetool_repair",
            "runner_selector" => %{"group" => "cassandra-us-east1"},
            "args" => %{"keyspace" => "system_auth"}
          }
        ]
      }
    })

  IO.puts(IO.ANSI.cyan() <> "✓ Seeded sample runbook" <> IO.ANSI.reset())
end

# -- A bootstrap auth key (only on first run) ------------------------
#
# If EMISAR_DEV_FIXED_AUTH_KEY is set in the environment (docker-compose
# does this), the seed inserts a key with that exact secret so the
# runner containers can read the same value from their EMISAR_AUTH_KEY
# env and register without any "capture-from-stdout" bootstrap dance.
#
# In production seeds, the env var is not set → we mint a random secret
# and print it once for the operator to copy. Hash-at-rest discipline
# is preserved in both paths; only the raw value's origin differs.

case Runners.list_auth_keys(account.id) do
  [] ->
    case System.get_env("EMISAR_DEV_FIXED_AUTH_KEY") do
      fixed when is_binary(fixed) and byte_size(fixed) >= 27 ->
        {:ok, _key} =
          Runners.create_auth_key_with_secret(fixed, account.id, user.id, %{
            description: "Dev fixed auth key (docker-compose)",
            group: "cassandra-us-east1",
            reusable: true
          })

        IO.puts(IO.ANSI.green() <> "✓ Seeded dev fixed auth key" <> IO.ANSI.reset())

      _ ->
        {:ok, raw, _key} =
          Runners.create_auth_key(account.id, user.id, %{
            description: "Demo auth key",
            group: "cassandra-us-east1",
            reusable: true
          })

        IO.puts("")
        IO.puts(IO.ANSI.green() <> "Bootstrap a runner:" <> IO.ANSI.reset())
        IO.puts("  curl -sSL https://emisar.com/install.sh | sudo EMISAR_AUTH_KEY=#{raw} bash")
        IO.puts("")
    end

    Audit.log(account.id, "auth_key.created",
      actor_kind: "system",
      subject_kind: "auth_key",
      payload: %{seeded: true}
    )

  _ ->
    :ok
end
