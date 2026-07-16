# Seeds for local dev. Run with `mix run apps/emisar/priv/repo/seeds.exs`
# or via `mix ecto.setup`. Idempotent — safe to re-run.
#
# Goal: produce a believable live-account state so the dashboard,
# runs list, approvals, runners, audit, and grants pages all show
# real-shaped data when an operator first opens the app — instead of
# empty-state cards everywhere.

alias Emisar.Accounts
alias Emisar.Accounts.Account
alias Emisar.ApiKeys
alias Emisar.Approvals
alias Emisar.Approvals.Request, as: ApprovalRequest
alias Emisar.Audit
alias Emisar.Auth
alias Emisar.Auth.Subject
alias Emisar.Billing
alias Emisar.Catalog
alias Emisar.Catalog.{PackBaseline, PackVersion}
alias Emisar.Policies
alias Emisar.Repo
alias Emisar.Runbooks
alias Emisar.Runners
alias Emisar.Runners.Runner
alias Emisar.Runs
alias Emisar.Users
alias Emisar.Users.User
# Approval emails go through Swoosh; in dev that's fine, but the seed
# shouldn't depend on the mailer being reachable.
Application.put_env(:emisar, :notify_approvers_async?, false)

now = fn -> DateTime.utc_now() end
mins_ago = &DateTime.add(now.(), -&1 * 60, :second)
hours_ago = &DateTime.add(now.(), -&1 * 3600, :second)
days_ago = &DateTime.add(now.(), -&1 * 86_400, :second)

# Plan now lives on the account's subscription (no `accounts.plan` column) —
# mint one for a paid tier; free accounts simply have no subscription.
# Idempotent: upsert_subscription peeks-then-updates, so re-seeding refreshes it.
seed_subscription = fn %Account{} = account, plan ->
  if plan != "free" do
    {:ok, _} = Billing.upsert_subscription(account.id, %{plan: plan, status: "active"})
  end

  account
end

confirm_user = fn
  %User{confirmed_at: nil} = user ->
    {:ok, confirmed} = user |> User.Changeset.confirm() |> Repo.update()
    confirmed

  %User{} = user ->
    user
end

ensure_profile = fn %User{} = user, full_name ->
  if user.full_name == full_name do
    user
  else
    {:ok, updated} = Users.update_user_profile(%{full_name: full_name}, %Subject{actor: user})
    updated
  end
end

clear_seeded_mfa = fn
  %User{mfa_enabled_at: nil} = user ->
    user

  %User{} = user ->
    {:ok, updated} = Auth.disable_mfa(%Subject{actor: user})
    updated
end

pack_descriptor = fn pack_id ->
  version =
    PackBaseline.current_version(pack_id) ||
      raise "missing shipped pack baseline for #{pack_id}"

  hash = PackBaseline.lookup(pack_id, version)

  if is_nil(hash) do
    raise "missing shipped-pack baseline for #{pack_id} #{version}"
  end

  %{"version" => version, "hash" => hash}
end

action_descriptor = fn pack_id, attrs ->
  Map.merge(
    %{
      "kind" => "exec",
      "risk" => "low",
      "side_effects" => [],
      "args" => [],
      "pack_id" => pack_id
    },
    attrs
  )
end

# Aggregate stream chunks: total byte size and sha256 of the
# concatenation. Used to populate ActionRun.{stdout,stderr}_{bytes,sha256}
# so the meta strip reads believably.
chunks_bytes = fn chunks, stream ->
  chunks
  |> Enum.filter(fn {s, _} -> s == stream end)
  |> Enum.reduce(0, fn {_, t}, acc -> acc + byte_size(t) end)
end

chunks_sha = fn chunks, stream ->
  blob =
    chunks
    |> Enum.filter(fn {s, _} -> s == stream end)
    |> Enum.map_join("", fn {_, t} -> t end)

  case blob do
    "" -> nil
    _ -> :crypto.hash(:sha256, blob) |> Base.encode16(case: :lower)
  end
end

# -- Demo account + owner --------------------------------------------

demo_account_name = "Northstar Labs"
demo_email = "demo@emisar.dev"
demo_full_name = "Maya Chen"

user =
  case Users.fetch_user_by_email(demo_email) do
    {:error, :not_found} ->
      {:ok, u} =
        Users.register_user(%{
          full_name: demo_full_name,
          email: demo_email,
          password: "Sleep-tight-1234"
        })

      u = confirm_user.(u)
      clear_seeded_mfa.(u)

    {:ok, %User{} = u} ->
      u = ensure_profile.(u, demo_full_name)
      u = confirm_user.(u)
      clear_seeded_mfa.(u)
  end

demo_account_query = Account.Query.not_deleted() |> Account.Query.by_slug("demo")

account =
  case Repo.fetch(demo_account_query, Account.Query) do
    {:error, :not_found} ->
      {:ok, account} =
        Accounts.create_account_with_owner(
          %{name: demo_account_name, slug: "demo"},
          user
        )

      account

    {:ok, account} ->
      account
  end

{:ok, owner_membership} = Accounts.fetch_membership_for_session(user, account.id)

owner_subject =
  Subject.for_user(user, account, owner_membership)

account =
  if account.name == demo_account_name do
    account
  else
    {:ok, updated} = Accounts.update_account(account, %{name: demo_account_name}, owner_subject)
    updated
  end

owner_subject = Subject.for_user(user, account, owner_membership)

# The demo account is enterprise so SSO/SCIM is testable here.
seed_subscription.(account, "enterprise")

# Retire the first-pass demo artifacts so re-running seeds upgrades an existing
# dev DB instead of preserving screenshot-hostile laptop/CI/cache-purge rows.
for email <- ["alex@emisar.dev", "sam@emisar.dev"] do
  case Users.fetch_user_by_email(email) do
    {:ok, old_user} ->
      old_user = clear_seeded_mfa.(old_user)

      case Accounts.peek_sync_membership(account.id, old_user.id) do
        nil ->
          :ok

        membership ->
          membership
          |> Emisar.Accounts.Membership.Changeset.delete()
          |> Repo.update!()
      end

    {:error, :not_found} ->
      :ok
  end
end

for name <- ["andrew-mbp", "ci-bot-runner", "edge-pop-fra"] do
  Runners.Runner.Query.not_deleted()
  |> Runners.Runner.Query.by_account_id(account.id)
  |> Runners.Runner.Query.by_name(name)
  |> Repo.delete_all()
end

case ApiKeys.list_api_keys_for_account(owner_subject, page: [limit: 100]) do
  {:ok, keys, _metadata} ->
    keys
    |> Enum.filter(&(&1.name == "Claude — Andrew's terminal"))
    |> Enum.each(fn key ->
      key
      |> Ecto.Changeset.change(deleted_at: now.())
      |> Repo.update!()
    end)

  _ ->
    :ok
end

case ApiKeys.list_audit_export_keys_for_account(owner_subject, page: [limit: 100]) do
  {:ok, keys, _metadata} ->
    keys
    |> Enum.filter(&(&1.name == "SIEM export — initial"))
    |> Enum.each(fn key ->
      key
      |> Ecto.Changeset.change(deleted_at: now.())
      |> Repo.update!()
    end)

  _ ->
    :ok
end

{:ok, legacy_runbooks, _metadata} = Runbooks.list_runbooks(owner_subject)

legacy_runbooks
|> Enum.filter(&(&1.slug == "nightly-edge-health"))
|> Enum.each(fn runbook ->
  runbook
  |> Ecto.Changeset.change(deleted_at: now.())
  |> Repo.update!()
end)

case Repo.fetch(Account.Query.not_deleted() |> Account.Query.by_slug("initech"), Account.Query) do
  {:ok, old_account} ->
    old_account
    |> Ecto.Changeset.change(deleted_at: now.())
    |> Repo.update!()

  {:error, :not_found} ->
    :ok
end

case Users.fetch_user_by_email("owner@initech.test") do
  {:ok, old_user} -> clear_seeded_mfa.(old_user)
  {:error, :not_found} -> :ok
end

IO.puts(
  IO.ANSI.cyan() <>
    "✓ #{demo_account_name} ready (slug=demo, owner=#{demo_email}, password=Sleep-tight-1234)" <>
    IO.ANSI.reset()
)

# -- Default policy ---------------------------------------------------

if Policies.peek_policy_for_account(account.id) == nil do
  {:ok, _} = Policies.seed_policy(account.id, user.id)
  IO.puts(IO.ANSI.cyan() <> "✓ Seeded default policy" <> IO.ANSI.reset())
end

# -- Invited teammates ------------------------------------------------

invite_member = fn email, full_name, role ->
  member =
    case Users.fetch_user_by_email(email) do
      {:ok, %User{} = existing_user} ->
        case Accounts.peek_sync_membership(account.id, existing_user.id) do
          nil ->
            {:ok, %{user: invited, membership: membership}} =
              Accounts.invite_user_to_account(email, role, owner_subject)

            {:ok, _membership} = Accounts.mark_invitation_accepted(membership, invited)
            invited

          membership ->
            if is_nil(membership.invitation_accepted_at) do
              {:ok, _membership} = Accounts.mark_invitation_accepted(membership, existing_user)
            end

            existing_user
        end

      {:error, :not_found} ->
        {:ok, %{user: invited, membership: membership}} =
          Accounts.invite_user_to_account(email, role, owner_subject)

        {:ok, _membership} = Accounts.mark_invitation_accepted(membership, invited)
        invited
    end

  member = ensure_profile.(member, full_name)
  member = confirm_user.(member)
  clear_seeded_mfa.(member)
end

jordan = invite_member.("jordan@emisar.dev", "Jordan Lee", "admin")
priya = invite_member.("priya@emisar.dev", "Priya Shah", "operator")
IO.puts(IO.ANSI.cyan() <> "✓ Teammates: Jordan (admin), Priya (operator)" <> IO.ANSI.reset())

# -- Sample runbook (skip if exists) ---------------------------------

{:ok, runbooks, _metadata} = Runbooks.list_runbooks(owner_subject)
morning_runbook = Enum.find(runbooks, &(&1.slug == "morning-edge-readiness"))

unless morning_runbook do
  {:ok, _rb} =
    Runbooks.create_runbook(
      %{
        name: "morning-edge-readiness",
        slug: "morning-edge-readiness",
        title: "Morning edge readiness",
        description:
          "08:00 UTC check across the edge-web group before the EU traffic peak: " <>
            "host load, disk pressure, and Caddy upstream health.",
        status: "published",
        definition: %{
          "steps" => [
            %{
              "id" => "uptime",
              "action_id" => "linux.uptime",
              "runner_selector" => %{"group" => ["edge-web"]}
            },
            %{
              "id" => "disk",
              "action_id" => "linux.disk_usage",
              "runner_selector" => %{"group" => ["edge-web"]}
            },
            %{
              "id" => "upstreams",
              "action_id" => "caddy.reverse_proxy_upstreams",
              "runner_selector" => %{"group" => ["edge-web"]}
            }
          ]
        }
      },
      owner_subject
    )

  IO.puts(IO.ANSI.cyan() <> "✓ Seeded sample runbook" <> IO.ANSI.reset())
end

# -- Runners ----------------------------------------------------------
#
# Production-shaped demo runners. The first three carry a fixed `external_id`
# that the docker-compose runner configs (dev/runners/<name>.yaml) pin as
# their `runner.id` — so when the live containers register they ADOPT these
# rows (online status from Presence, while the seeded catalog + run history
# stay attached) instead of creating separate empty runners. The fourth has
# no container, so it stays offline — the realistic "host currently down" row
# for the fleet screenshots. `external_id` is the identity; names are display.

runner_specs = [
  %{
    name: "edge-fra-01",
    external_id: "edge-fra-01",
    group: "edge-web",
    hostname: "edge-fra-01.northstar.example",
    labels: %{"env" => "prod", "region" => "eu-central", "role" => "edge"},
    state: :connected,
    version: "0.10.0",
    last_seen_min: 2
  },
  %{
    name: "api-iad-02",
    external_id: "api-iad-02",
    group: "app-api",
    hostname: "api-iad-02.northstar.example",
    labels: %{"env" => "prod", "region" => "us-east-1", "service" => "checkout"},
    state: :connected,
    version: "0.4.2",
    last_seen_min: 4
  },
  %{
    name: "pg-primary-iad",
    external_id: "pg-primary-iad",
    group: "data-postgres",
    hostname: "pg-primary-iad.northstar.example",
    labels: %{"env" => "prod", "region" => "us-east-1", "role" => "primary"},
    state: :connected,
    version: "0.10.0",
    last_seen_min: 6
  },
  %{
    name: "edge-sfo-03",
    external_id: "edge-sfo-03",
    group: "edge-web",
    hostname: "edge-sfo-03.northstar.example",
    labels: %{"env" => "prod", "region" => "us-west-2", "role" => "edge"},
    state: :disconnected,
    disconnect_reason: "drained for kernel upgrade",
    version: "0.10.0",
    last_seen_min: 140
  }
]

# Seed runners through the registration changeset; the public product path is
# enrollment-key self-registration, not an operator-created runner row. Seeded
# names are deterministic, so they are also the stable identity unless a fixture
# explicitly models a different external id.
insert_seed_runner = fn account_id, attrs ->
  attrs
  |> Map.put(:account_id, account_id)
  |> Map.put_new(:external_id, Map.fetch!(attrs, :name))
  |> Runner.Changeset.register()
  |> Repo.insert()
end

ensure_runner = fn spec ->
  {:ok, all_runners, _} = Runners.list_runners_for_account(owner_subject)

  case Enum.find(all_runners, &(&1.name == spec.name)) do
    %{} = existing ->
      existing
      |> Ecto.Changeset.change(
        external_id: spec.external_id,
        group: spec.group,
        labels: spec.labels
      )
      |> Repo.update!()

    nil ->
      {:ok, r} =
        insert_seed_runner.(
          account.id,
          %{
            name: spec.name,
            external_id: spec.external_id,
            group: spec.group,
            hostname: spec.hostname,
            labels: spec.labels,
            runner_version: spec.version
          }
        )

      r
  end
end

stamp_runner_state = fn runner, spec ->
  # Connection state is Phoenix.Presence — it can't be seeded (no live
  # socket), so we backdate the durable "last seen" history only. The three
  # :connected rows flip to truly online the moment their docker container
  # adopts them (matched by external_id); the :disconnected row has no
  # container, so it stays offline with this last-seen + disconnect reason.
  seen_at = mins_ago.(spec.last_seen_min)

  attrs =
    case spec.state do
      :connected ->
        %{last_connected_at: seen_at}

      :disconnected ->
        %{
          last_connected_at: mins_ago.(spec.last_seen_min + 60),
          last_disconnected_at: seen_at,
          last_disconnect_reason: spec[:disconnect_reason] || "websocket dropped"
        }
    end
    |> Map.merge(%{
      group: spec.group,
      hostname: spec.hostname,
      labels: spec.labels,
      runner_version: spec.version
    })

  runner
  |> Ecto.Changeset.change(attrs)
  |> Repo.update!()
end

runners =
  Enum.map(runner_specs, fn spec ->
    spec |> ensure_runner.() |> stamp_runner_state.(spec)
  end)

IO.puts(
  IO.ANSI.cyan() <>
    "✓ Seeded #{length(runners)} demo runners (3 adopted by docker containers on boot, 1 offline)" <>
    IO.ANSI.reset()
)

# -- Catalog: actions on each runner ---------------------------------

linux_actions = [
  action_descriptor.("linux-core", %{
    "id" => "linux.uptime",
    "title" => "System uptime and load average",
    "risk" => "low",
    "description" => "Reports system uptime and 1/5/15-minute load averages.",
    "args" => []
  }),
  action_descriptor.("linux-core", %{
    "id" => "linux.disk_usage",
    "title" => "Filesystem disk usage",
    "risk" => "low",
    "description" => "Reports filesystem usage for supplied paths using df.",
    "args" => [
      %{"name" => "paths", "type" => "string_array", "required" => false}
    ]
  }),
  action_descriptor.("linux-core", %{
    "id" => "linux.journalctl",
    "title" => "Recent systemd journal entries",
    "risk" => "medium",
    "description" => "Reads recent systemd journal entries for a named unit.",
    "args" => [
      %{"name" => "unit", "type" => "string", "required" => true},
      %{"name" => "since", "type" => "duration", "required" => false},
      %{"name" => "priority", "type" => "string", "required" => false}
    ]
  })
]

edge_actions = [
  action_descriptor.("caddy", %{
    "id" => "caddy.version",
    "title" => "caddy version",
    "risk" => "low",
    "description" => "Prints the running Caddy version.",
    "args" => []
  }),
  action_descriptor.("caddy", %{
    "id" => "caddy.reverse_proxy_upstreams",
    "title" => "GET /reverse_proxy/upstreams",
    "risk" => "low",
    "description" => "Lists all reverse-proxy upstreams with current health.",
    "args" => []
  }),
  action_descriptor.("caddy", %{
    "id" => "caddy.access_log_tail",
    "title" => "tail caddy access log",
    "risk" => "low",
    "description" => "Tails the access log with a bounded line count.",
    "args" => [%{"name" => "lines", "type" => "integer", "required" => false}]
  }),
  action_descriptor.("caddy", %{
    "id" => "caddy.validate_config",
    "title" => "caddy validate --config <file>",
    "risk" => "low",
    "description" => "Validates a Caddy config without applying it.",
    "args" => [%{"name" => "file", "type" => "string", "required" => false}]
  }),
  action_descriptor.("caddy", %{
    "id" => "caddy.reload_config",
    "title" => "caddy reload --config <file>",
    "risk" => "high",
    "description" => "Live-swaps the running Caddy config after validation.",
    "side_effects" => ["Replaces the in-memory config atomically."],
    "args" => [%{"name" => "file", "type" => "string", "required" => false}]
  })
]

api_actions = [
  action_descriptor.("systemd-deep", %{
    "id" => "systemd.failed_units",
    "title" => "Failed systemd units",
    "risk" => "low",
    "description" => "Lists units not in active state with their last failure reason.",
    "args" => []
  }),
  action_descriptor.("systemd-deep", %{
    "id" => "systemd.unit_show",
    "title" => "systemctl show <unit>",
    "risk" => "low",
    "description" => "Shows systemd properties for one unit.",
    "args" => [%{"name" => "unit", "type" => "string", "required" => true}]
  }),
  action_descriptor.("systemd-deep", %{
    "id" => "systemd.unit_restart",
    "title" => "systemctl restart <unit>",
    "risk" => "high",
    "description" => "Restarts one workload-bearing systemd unit.",
    "side_effects" => ["Service stopped then started."],
    "args" => [%{"name" => "unit", "type" => "string", "required" => true}]
  })
]

postgres_actions = [
  action_descriptor.("postgres", %{
    "id" => "postgres.replication_lag",
    "title" => "Replication lag (primary view)",
    "risk" => "low",
    "description" => "Reports replication slot health from the primary's perspective.",
    "args" => []
  }),
  action_descriptor.("postgres", %{
    "id" => "postgres.vacuum_status",
    "title" => "Autovacuum + bloat snapshot",
    "risk" => "low",
    "description" => "Returns dead-tuple counts and vacuum timestamps by table.",
    "args" => [
      %{"name" => "schema", "type" => "string", "required" => false},
      %{"name" => "limit", "type" => "integer", "required" => false}
    ]
  }),
  action_descriptor.("postgres", %{
    "id" => "postgres.reload_conf",
    "title" => "Reload postgresql.conf",
    "risk" => "high",
    "description" => "Calls pg_reload_conf() to re-read server config.",
    "side_effects" => ["Server re-reads postgresql.conf and pg_hba.conf."],
    "args" => []
  })
]

advertise = fn runner, actions ->
  packs =
    actions
    |> Enum.map(& &1["pack_id"])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Map.new(fn pack_id -> {pack_id, pack_descriptor.(pack_id)} end)

  payload = %{
    "hostname" => runner.hostname,
    "labels" => runner.labels || %{},
    "version" => runner.runner_version,
    "packs" => packs,
    "actions" => actions
  }

  {:ok, _} = Catalog.observe_state(runner, payload)
end

Enum.each(runners, fn r ->
  case r.group do
    "edge-web" -> advertise.(r, edge_actions ++ linux_actions)
    "app-api" -> advertise.(r, api_actions ++ linux_actions)
    "data-postgres" -> advertise.(r, postgres_actions ++ linux_actions)
    _ -> advertise.(r, linux_actions)
  end
end)

PackVersion.Query.all()
|> PackVersion.Query.by_account_id(account.id)
|> PackVersion.Query.by_pack_id("showcase")
|> Repo.delete_all()

IO.puts(IO.ANSI.cyan() <> "✓ Advertised actions on every runner" <> IO.ANSI.reset())

# -- Runs across various states --------------------------------------
#
# Skip everything below if any runs already exist — we don't want
# duplicate seed data to pile up on re-runs.

policy = Policies.peek_policy_for_account(account.id)

# Pull each seeded runner out by name so the run-seeding code reads
# like prose.
edge = Enum.find(runners, &(&1.name == "edge-fra-01"))
api = Enum.find(runners, &(&1.name == "api-iad-02"))
database = Enum.find(runners, &(&1.name == "pg-primary-iad"))

# -- LLM-bridge API key (an "agent") --------------------------------
#
# A personality-rich MCP key so the agents page has a real-looking
# row and we can attribute some of the historical runs to it. The
# audit log entries the create_key call writes give the Audit page
# an actor=api_key example, too.
#
# In the docker stack EMISAR_DEV_FIXED_MCP_KEY is set, so this key is
# minted with that well-known raw value and the `mcp` compose service can
# drive the bridge with no manual minting. Locally (no env) it's a random
# secret like any real key.

agent_key_name = "Claude Code - on-call"

agent_key_attrs = %{
  name: agent_key_name,
  description:
    "MCP bridge used by the on-call engineer for read-only triage and " <>
      "approval-gated remediation."
}

agent_key =
  case ApiKeys.list_api_keys_for_account(owner_subject, page: [limit: 100]) do
    {:ok, keys, _} ->
      Enum.find(keys, &(&1.name == agent_key_name))

    _ ->
      nil
  end

fixed_agent_key =
  case System.get_env("EMISAR_DEV_FIXED_MCP_KEY") do
    nil ->
      nil

    "emk-" <> encoded = fixed ->
      case Base.url_decode64(encoded, padding: false) do
        {:ok, secret} when byte_size(secret) == 32 -> fixed
        _ -> raise "EMISAR_DEV_FIXED_MCP_KEY must be an emk- key with 32 random bytes"
      end

    _ ->
      raise "EMISAR_DEV_FIXED_MCP_KEY must be an emk- key with 32 random bytes"
  end

agent_key =
  case {agent_key, fixed_agent_key} do
    {nil, nil} ->
      {:ok, _raw_agent, key} = ApiKeys.create_key(agent_key_attrs, owner_subject)
      key

    {nil, fixed} ->
      # Build the row the way create_key does — Crypto.mint's prefix is the
      # first 12 chars (ApiKeys @prefix_size) and the hash is Crypto.hash(raw),
      # which is exactly what peek_api_key_by_secret recomputes on lookup.
      # §7: seeds build rows directly rather than via a seed-only context fn.
      {:ok, key} =
        ApiKeys.ApiKey.Changeset.create(
          account.id,
          user.id,
          owner_membership.id,
          String.slice(fixed, 0, 12),
          Emisar.Crypto.hash(fixed),
          agent_key_attrs
        )
        |> Repo.insert()

      key

    {%ApiKeys.ApiKey{} = key, nil} ->
      key

    {%ApiKeys.ApiKey{} = key, fixed} ->
      # A repeated dev seed must converge the persisted row with Compose's
      # fixed secret, even after a rotation or the default expiry elapsed.
      key
      |> Ecto.Changeset.change(
        key_prefix: String.slice(fixed, 0, 12),
        key_hash: Emisar.Crypto.hash(fixed),
        expires_at: DateTime.add(now.(), 30 * 86_400, :second),
        revoked_at: nil,
        revoked_by_id: nil,
        replaces_id: nil,
        rotated_to_id: nil
      )
      |> Repo.update!()
  end
  |> Ecto.Changeset.change(
    last_used_at: mins_ago.(9),
    last_client_info: %{"name" => "Claude Code", "version" => "1.0.0"}
  )
  |> Repo.update!()

IO.puts(IO.ANSI.cyan() <> "✓ Seeded MCP API key for the LLM agent" <> IO.ANSI.reset())

# -- Audit-export key ------------------------------------------------
#
# Mirrors the "Mint export token" button on the audit page so a
# freshly-seeded demo account already shows what the SIEM workflow
# looks like — a separate token on the audit page whose `:audit_export`
# kind can reach only the read-only audit endpoint.

export_key_name = "SIEM export - Datadog intake"

export_key =
  case ApiKeys.list_audit_export_keys_for_account(owner_subject, page: [limit: 100]) do
    {:ok, keys, _} ->
      Enum.find(keys, &(&1.name == export_key_name))

    _ ->
      nil
  end

case export_key do
  nil ->
    {:ok, _raw_export, key} =
      ApiKeys.create_key(
        %{
          name: export_key_name,
          description:
            "Streams audit events as NDJSON to the security team's SIEM. " <>
              "Read-only; no dispatch rights.",
          kind: :audit_export
        },
        owner_subject
      )

    key

  key ->
    key
end
|> Ecto.Changeset.change(last_used_at: hours_ago.(6))
|> Repo.update!()

IO.puts(IO.ANSI.cyan() <> "✓ Seeded audit-export API key" <> IO.ANSI.reset())

existing_runs =
  case Runs.list_recent_runs(owner_subject, limit: 1) do
    {:ok, list, _meta} -> list
    _ -> []
  end

if existing_runs == [] do
  insert_run = fn attrs ->
    {:ok, run} =
      attrs
      |> Map.merge(%{
        account_id: account.id,
        source: attrs[:source] || "operator",
        requested_by_id: attrs[:requested_by_id] || user.id,
        policy_id: policy && policy.id,
        policy_decision: attrs[:policy_decision] || "allow",
        policy_reason: attrs[:policy_reason] || "Default for low-risk actions"
      })
      |> Runs.create_run()

    run
  end

  # Backdate a run by editing the row after insertion.
  backdate = fn run, datetime ->
    run
    |> Ecto.Changeset.change(inserted_at: datetime, queued_at: datetime)
    |> Repo.update!()
  end

  backdate_request = fn request, requested_at ->
    request
    |> Ecto.Changeset.change(
      requested_at: requested_at,
      expires_at: DateTime.add(requested_at, 24 * 3600, :second)
    )
    |> Repo.update!()
  end

  # Append a synthetic stdout/stderr chunk to a run so the RunDetail
  # output panel shows realistic terminal output. `seq` is the unique
  # per-run sequence; chunks render in seq order.
  append_chunks = fn run, chunks ->
    Enum.with_index(chunks, 1)
    |> Enum.each(fn {{stream, text}, seq} ->
      {:ok, _} =
        Runs.append_event(run, %{
          seq: seq,
          kind: "progress",
          stream: stream,
          payload: %{"chunk" => text}
        })
    end)
  end

  # Wrap finalize_success to take the realistic-output blob too, and
  # update bytes/sha so the meta strip reads believably.
  finalize_success = fn run, finished_at, duration_ms, chunks ->
    append_chunks.(run, chunks)

    {:ok, run} =
      Runs.mark_finished(run, %{
        "status" => "success",
        "exit_code" => 0,
        "duration_ms" => duration_ms,
        "emitted_stdout_bytes" => chunks_bytes.(chunks, "stdout"),
        "emitted_stderr_bytes" => chunks_bytes.(chunks, "stderr"),
        "emitted_stdout_sha256" => chunks_sha.(chunks, "stdout"),
        "emitted_stderr_sha256" => chunks_sha.(chunks, "stderr"),
        "progress_chunks" => length(chunks),
        "event_id" => "seed-" <> Ecto.UUID.generate()
      })

    run
    |> Ecto.Changeset.change(
      finished_at: finished_at,
      sent_at: DateTime.add(finished_at, -duration_ms, :millisecond)
    )
    |> Repo.update!()
  end

  finalize_failure = fn run, finished_at, exit_code, reason, chunks ->
    append_chunks.(run, chunks)

    {:ok, run} =
      Runs.mark_finished(run, %{
        "status" => "failed",
        "exit_code" => exit_code,
        "duration_ms" => 4500,
        "reason" => reason,
        "emitted_stdout_bytes" => chunks_bytes.(chunks, "stdout"),
        "emitted_stderr_bytes" => chunks_bytes.(chunks, "stderr"),
        "emitted_stdout_sha256" => chunks_sha.(chunks, "stdout"),
        "emitted_stderr_sha256" => chunks_sha.(chunks, "stderr"),
        "progress_chunks" => length(chunks),
        "event_id" => "seed-" <> Ecto.UUID.generate()
      })

    run
    |> Ecto.Changeset.change(finished_at: finished_at)
    |> Repo.update!()
  end

  # Realistic synthetic output per action — built once, reused below.
  # Each entry is a list of `{stream, chunk_text}` tuples.
  uptime_stdout = [
    {"stdout", " 14:02:31 up 18 days,  4:11,  3 users,  load average: 0.41, 0.28, 0.22\n"}
  ]

  df_stdout = [
    {"stdout",
     "Filesystem      Size  Used Avail Use% Mounted on\n" <>
       "/dev/nvme0n1p1  457G  221G  213G  51% /\n" <>
       "tmpfs            16G  124M   16G   1% /run\n" <>
       "/dev/nvme0n1p2  1.8T  1.4T  316G  82% /var/lib/data\n"}
  ]

  caddy_upstreams_stdout = [
    {"stdout",
     Jason.encode!(%{
       "upstreams" => [
         %{"address" => "10.42.8.12:8443", "healthy" => true, "requests" => 1284},
         %{"address" => "10.42.8.13:8443", "healthy" => true, "requests" => 1198}
       ]
     }) <> "\n"}
  ]

  caddy_access_stdout = [
    {"stdout", "203.0.113.21 - - \"GET /checkout\" 200 4821 34ms\n"},
    {"stdout", "198.51.100.44 - - \"POST /api/cart\" 200 812 41ms\n"},
    {"stdout", "203.0.113.29 - - \"GET /assets/app.css\" 304 0 2ms\n"}
  ]

  caddy_reload_stdout = [
    {"stdout", "2026/06/24 11:12:08.214 INFO using adjacent Caddyfile\n"},
    {"stdout", "2026/06/24 11:12:08.481 INFO autosaved config\n"},
    {"stdout", "2026/06/24 11:12:08.482 INFO serving initial configuration\n"}
  ]

  caddy_validate_failure = [
    {"stderr",
     "Error: adapting config using caddyfile: upstream app-blue.internal:8443: no healthy SRV records\n"}
  ]

  journalctl_stdout = [
    {"stdout",
     "-- Logs begin at Sat 2026-05-30 09:01:00 UTC. --\n" <>
       "Jun 24 13:51:02 api-iad-02 checkout-api[1184]: latency budget recovered p95=184ms\n" <>
       "Jun 24 13:55:14 api-iad-02 checkout-api[1184]: deploy marker sha=6b7c19d\n"}
  ]

  postgres_lag_stdout = [
    {"stdout", "checkout-read-1|10.42.12.41|streaming|async|0|16384\n"},
    {"stdout", "checkout-read-2|10.42.12.42|streaming|async|0|32768\n"}
  ]

  postgres_vacuum_stdout = [
    {"stdout", "public|orders|1842021|12804|0.69|2026-06-24 10:41:02|2026-06-24 13:20:11\n"},
    {"stdout", "public|carts|931044|8092|0.86|2026-06-24 09:12:18|2026-06-24 13:04:52\n"}
  ]

  systemd_failed_stdout = [
    {"stdout", "0 loaded units listed.\n"}
  ]

  systemd_restart_output = [
    {"stdout", "Stopping checkout-api.service...\n"},
    {"stdout", "Started checkout-api.service.\n"}
  ]

  # Successful operator-driven runs across the last 36 hours.
  successes = [
    {edge, "linux.uptime", mins_ago.(8), 320, %{}, priya, "morning edge readiness",
     uptime_stdout},
    {edge, "caddy.reverse_proxy_upstreams", mins_ago.(24), 610, %{}, jordan,
     "verify checkout upstream health after deploy", caddy_upstreams_stdout},
    {database, "postgres.replication_lag", mins_ago.(46), 840, %{}, user,
     "confirm replicas caught up after catalog import", postgres_lag_stdout},
    {api, "systemd.failed_units", hours_ago.(3), 530, %{}, priya, "pre-handoff health sweep",
     systemd_failed_stdout},
    {database, "postgres.vacuum_status", hours_ago.(7), 1200,
     %{"schema" => "public", "limit" => 20}, jordan, "check autovacuum before traffic peak",
     postgres_vacuum_stdout},
    {edge, "linux.disk_usage", hours_ago.(12), 280, %{"paths" => ["/", "/var/log"]}, user,
     "weekly capacity check", df_stdout},
    {api, "linux.journalctl", hours_ago.(19), 900,
     %{"unit" => "checkout-api.service", "since" => "2h", "priority" => "warning"}, priya,
     "review checkout-api warnings after release", journalctl_stdout}
  ]

  # MCP/agent-driven runs — these are what Claude dispatches over the
  # bridge. source: "mcp", api_key_id is the agent key. Reason text
  # includes the LLM's prompt summary so it's obvious in the UI who
  # asked.
  agent_runs = [
    {edge, "caddy.access_log_tail", mins_ago.(14), 260, %{"lines" => 50},
     "Maya via Claude: summarize checkout traffic after the deploy", caddy_access_stdout},
    {edge, "caddy.reverse_proxy_upstreams", mins_ago.(31), 690, %{},
     "Maya via Claude: check whether edge upstreams are healthy", caddy_upstreams_stdout},
    {database, "postgres.replication_lag", hours_ago.(2), 620, %{},
     "Maya via Claude: confirm replica lag before the email campaign", postgres_lag_stdout}
  ]

  Enum.each(successes, fn {runner, action_id, started_at, dur_ms, args, who, reason, chunks} ->
    finished_at = DateTime.add(started_at, dur_ms, :millisecond)

    insert_run.(%{
      runner_id: runner.id,
      action_id: action_id,
      args: args,
      reason: reason,
      requested_by_id: who.id,
      status: "running"
    })
    |> backdate.(started_at)
    |> finalize_success.(finished_at, dur_ms, chunks)
  end)

  Enum.each(agent_runs, fn {runner, action_id, started_at, dur_ms, args, reason, chunks} ->
    finished_at = DateTime.add(started_at, dur_ms, :millisecond)

    insert_run.(%{
      runner_id: runner.id,
      action_id: action_id,
      args: args,
      reason: reason,
      requested_by_id: user.id,
      source: "mcp",
      api_key_id: agent_key.id,
      status: "running"
    })
    |> backdate.(started_at)
    |> finalize_success.(finished_at, dur_ms, chunks)
  end)

  # A single old failure for filters/detail screenshots. It is outside the
  # dashboard's 24h headline so the default account reads healthy.
  failed_specs = [
    {edge, "caddy.validate_config", days_ago.(5), 1, "config validation failed before reload",
     %{"file" => "/etc/caddy/Caddyfile"}, jordan, caddy_validate_failure}
  ]

  Enum.each(failed_specs, fn {runner, action_id, started_at, exit_code, reason, args, who, chunks} ->
    finished_at = DateTime.add(started_at, 4500, :millisecond)

    insert_run.(%{
      runner_id: runner.id,
      action_id: action_id,
      args: args,
      reason: "manual investigation",
      requested_by_id: who.id,
      status: "running"
    })
    |> backdate.(started_at)
    |> finalize_failure.(finished_at, exit_code, reason, chunks)
  end)

  # One old cancelled run. It gives the Runs filters a realistic terminal
  # non-error without putting a fresh warning on the dashboard.
  cancelled_at = days_ago.(3)

  cancelled =
    insert_run.(%{
      runner_id: api.id,
      action_id: "systemd.unit_restart",
      args: %{"unit" => "checkout-api.service"},
      reason: "cancel after canary rollback completed elsewhere",
      requested_by_id: jordan.id,
      status: "running"
    })
    |> backdate.(cancelled_at)

  append_chunks.(cancelled, systemd_restart_output)

  {:ok, cancelled} =
    Runs.mark_finished(cancelled, %{"status" => "cancelled"})

  cancelled
  |> Ecto.Changeset.change(
    finished_at: cancelled_at,
    cancelled_at: cancelled_at,
    reason_text: "operator cancelled - rollback already completed"
  )
  |> Repo.update!()

  IO.puts(
    IO.ANSI.cyan() <>
      "✓ Seeded #{length(successes) + length(agent_runs)} recent successes (#{length(agent_runs)} via MCP agent), 1 old failure, 1 old cancellation" <>
      IO.ANSI.reset()
  )

  # -- Pending approvals (so dashboard "Needs attention" lights up) ---
  #
  # Mix of human-initiated + agent-initiated requests so the approvals
  # page shows both shapes. Priya files the routine one; Claude (the
  # MCP agent) asks for a high-risk restart and gets held.

  pending1_at = mins_ago.(6)

  pending1 =
    insert_run.(%{
      runner_id: edge.id,
      action_id: "caddy.reload_config",
      args: %{"file" => "/etc/caddy/Caddyfile"},
      reason: "apply checked-in Caddyfile after certificate renewal",
      requested_by_id: priya.id,
      status: "pending_approval",
      requires_approval: true,
      policy_decision: "require_approval",
      policy_reason: "High-risk config reload requires an admin approval"
    })
    |> backdate.(pending1_at)

  {:ok, req1} =
    Approvals.create_request(
      pending1,
      priya.id,
      "Config was validated in CI; needs an admin approval before the edge reload."
    )

  backdate_request.(req1, pending1_at)

  # Agent-initiated pending — note source: "mcp", api_key_id set.
  pending2_at = mins_ago.(22)

  pending2 =
    insert_run.(%{
      runner_id: api.id,
      action_id: "systemd.unit_restart",
      args: %{"unit" => "checkout-api.service"},
      reason: "Maya via Claude: restart checkout-api after deploy smoke test",
      requested_by_id: user.id,
      source: "mcp",
      api_key_id: agent_key.id,
      status: "pending_approval",
      requires_approval: true,
      policy_decision: "require_approval",
      policy_reason: "Service restart is high-risk and requires human approval"
    })
    |> backdate.(pending2_at)

  {:ok, req2} =
    Approvals.create_request(
      pending2,
      user.id,
      "Agent proposed a restart after the smoke test. Hold for the deploy captain."
    )

  backdate_request.(req2, pending2_at)

  # An already-approved one (just to show history in the approvals
  # list filter when an operator clicks "Approved").
  approved_at = hours_ago.(26)

  approved_run =
    insert_run.(%{
      runner_id: edge.id,
      action_id: "caddy.reload_config",
      args: %{"file" => "/etc/caddy/Caddyfile"},
      reason: "Maya via Claude: reload Caddy after config validation",
      requested_by_id: user.id,
      source: "mcp",
      api_key_id: agent_key.id,
      status: "pending_approval",
      requires_approval: true,
      policy_decision: "require_approval",
      policy_reason: "High-risk config reload requires an admin approval"
    })
    |> backdate.(approved_at)

  {:ok, %ApprovalRequest{} = approved_req} =
    Approvals.create_request(approved_run, user.id, "reload after config validation")

  approved_req = backdate_request.(approved_req, approved_at)

  # Manually mark approved (don't actually dispatch) + backdate the
  # decision so it doesn't pollute "pending" lists.
  approved_req
  |> Ecto.Changeset.change(
    status: :approved,
    decided_by_id: jordan.id,
    decided_at: hours_ago.(25),
    decision_reason: "validated config, active connections drained, deploy window open"
  )
  |> Repo.update!()

  append_chunks.(approved_run, caddy_reload_stdout)

  approved_run
  |> Ecto.Changeset.change(
    status: :success,
    sent_at: DateTime.add(hours_ago.(24), -2, :second),
    started_at: DateTime.add(hours_ago.(24), -2, :second),
    finished_at: hours_ago.(24),
    exit_code: 0,
    duration_ms: 1820,
    emitted_stdout_bytes: chunks_bytes.(caddy_reload_stdout, "stdout"),
    emitted_stderr_bytes: chunks_bytes.(caddy_reload_stdout, "stderr"),
    emitted_stdout_sha256: chunks_sha.(caddy_reload_stdout, "stdout"),
    emitted_stderr_sha256: chunks_sha.(caddy_reload_stdout, "stderr"),
    output_complete: true
  )
  |> Repo.update!()

  # A denied one too.
  denied_at = days_ago.(3)

  denied_run =
    insert_run.(%{
      runner_id: database.id,
      action_id: "postgres.reload_conf",
      args: %{},
      reason: "Maya via Claude: reload Postgres config before change ticket is approved",
      requested_by_id: user.id,
      source: "mcp",
      api_key_id: agent_key.id,
      status: "pending_approval",
      requires_approval: true,
      policy_decision: "require_approval",
      policy_reason: "Database config reload requires approved change window"
    })
    |> backdate.(denied_at)

  {:ok, denied_req} =
    Approvals.create_request(
      denied_run,
      user.id,
      "Agent proposed a Postgres reload before the change ticket was approved."
    )

  denied_req = backdate_request.(denied_req, denied_at)

  denied_req
  |> Ecto.Changeset.change(
    status: :denied,
    decided_by_id: jordan.id,
    decided_at: days_ago.(3),
    decision_reason: "Wait for the DBA-approved change window."
  )
  |> Repo.update!()

  denied_run
  |> Ecto.Changeset.change(
    status: :cancelled,
    finished_at: denied_at,
    cancelled_at: denied_at,
    reason_text: "approval denied: Wait for the DBA-approved change window."
  )
  |> Repo.update!()

  IO.puts(
    IO.ANSI.cyan() <>
      "✓ Seeded 2 pending (1 from agent) + 1 approved + 1 denied approval requests" <>
      IO.ANSI.reset()
  )

  # -- Standing grants ------------------------------------------------
  #
  # Two grants tied to the agent key — so the LLM can call these
  # specific actions without re-asking. Demonstrates the "ask once,
  # then run autonomously" workflow on the Grants page.

  for {action, runner_id, scope, duration} <- [
        {"caddy.access_log_tail", edge.id, :any_args, :thirty_days},
        {"postgres.replication_lag", database.id, :any_args, :thirty_days}
      ] do
    fake_run = %Runs.ActionRun{
      account_id: account.id,
      api_key_id: agent_key.id,
      runner_id: runner_id,
      action_id: action,
      args_sha256: :crypto.hash(:sha256, "{}") |> Base.encode16(case: :lower)
    }

    {:ok, _grant} =
      Approvals.create_grant(approved_req, fake_run, user.id, %{
        duration: duration,
        scope: scope
      })
  end

  IO.puts(IO.ANSI.cyan() <> "✓ Seeded 2 standing grants for the agent" <> IO.ANSI.reset())

  # -- A handful of plain audit events --------------------------------
  #
  # Most of the above already wrote audit rows (approval.*, runner.*,
  # run.*); add a couple of operator-action events so the audit page
  # shows variety.

  Audit.log(account.id, "user.signed_in",
    actor_kind: "user",
    actor_id: jordan.id,
    payload: %{ip: "203.0.113.42"}
  )

  Audit.log(account.id, "user.signed_in",
    actor_kind: "user",
    actor_id: priya.id,
    payload: %{ip: "198.51.100.17"}
  )
end

# -- Bootstrap auth key (unchanged) ----------------------------------

case Runners.list_enrollment_keys(owner_subject) do
  {:ok, [], _} ->
    case System.get_env("EMISAR_DEV_FIXED_AUTH_KEY") do
      fixed when is_binary(fixed) and byte_size(fixed) >= 27 ->
        {:ok, _key} =
          Emisar.Runners.EnrollmentKey.Changeset.create_with_secret(account.id, user.id, fixed, %{
            description: "Dev fixed auth key (docker-compose)",
            group: "dev-docker",
            reusable: true
          })
          |> Repo.insert()

        IO.puts(IO.ANSI.green() <> "✓ Seeded dev fixed auth key" <> IO.ANSI.reset())

      _ ->
        {:ok, raw, _key} =
          Runners.create_enrollment_key(
            %{
              description: "Demo auth key",
              group: "edge-web",
              reusable: true
            },
            owner_subject
          )

        IO.puts("")
        IO.puts(IO.ANSI.green() <> "Bootstrap a runner:" <> IO.ANSI.reset())
        IO.puts("  curl -sSL https://emisar.dev/install.sh | sudo EMISAR_AUTH_KEY=#{raw} bash")
        IO.puts("")
    end

    Audit.log(account.id, "enrollment_key.created",
      actor_kind: "system",
      target_kind: "enrollment_key",
      payload: %{seeded: true}
    )

  _ ->
    :ok
end

# -- Keycloak OIDC + SCIM provider (docker-compose e2e SSO) ----------
# Seeds an enabled :keycloak IdentityProvider on the demo (enterprise) account
# pointing at the local Keycloak, plus a fixed dev SCIM bearer — so `docker
# compose up` exercises OIDC login AND inbound SCIM provisioning end to end.
# Gated on the same fixed-dev-value env vars as the auth/MCP keys; a no-op when
# unset, so a prod-style seed never creates an IdP. Idempotent (skips if the
# account already has a provider).
keycloak_secret = System.get_env("EMISAR_DEV_FIXED_OIDC_CLIENT_SECRET")

keycloak_present? =
  Emisar.SSO.IdentityProvider.Query.not_deleted()
  |> Emisar.SSO.IdentityProvider.Query.by_account_id(account.id)
  |> Repo.exists?()

if not keycloak_present? and is_binary(keycloak_secret) and keycloak_secret != "" do
  issuer = System.get_env("EMISAR_DEV_KEYCLOAK_ISSUER") || "https://keycloak:8443/realms/emisar"
  # Fixed id so the e2e driver can begin the flow at /sign_in/sso/<id> with no DB lookup.
  provider_id =
    System.get_env("EMISAR_DEV_KEYCLOAK_PROVIDER_ID") || "11111111-1111-7111-8111-111111111111"

  # Build the row directly (Changeset.change, not create): the dev Keycloak runs
  # as the portal's localhost sidecar, so its issuer is a loopback URL — which
  # `IssuerUrl` (the SSRF guard in Changeset.create) correctly rejects for
  # OPERATOR-supplied issuers. The seed is trusted infra pointing at a known dev
  # provider, not attacker input, so it bypasses that guard; the console config
  # path stays fully guarded.
  {:ok, provider} =
    %Emisar.SSO.IdentityProvider{}
    |> Ecto.Changeset.change(%{
      id: provider_id,
      account_id: account.id,
      kind: :keycloak,
      name: "Keycloak (dev)",
      issuer: issuer,
      client_id: System.get_env("EMISAR_DEV_KEYCLOAK_CLIENT_ID") || "emisar-portal",
      client_secret: keycloak_secret,
      identifier_claim: :sub,
      default_role: :operator,
      satisfies_mfa: true,
      provisioner: :jit,
      enabled: true
    })
    |> Repo.insert()

  IO.puts(IO.ANSI.green() <> "✓ Seeded Keycloak OIDC provider (#{issuer})" <> IO.ANSI.reset())

  case System.get_env("EMISAR_DEV_FIXED_SCIM_TOKEN") do
    raw when is_binary(raw) and byte_size(raw) > 12 ->
      {:ok, _} =
        provider
        |> Emisar.SSO.IdentityProvider.Changeset.scim_token(
          String.slice(raw, 0, 12),
          Emisar.Crypto.hash(raw),
          true
        )
        |> Repo.update()

      IO.puts(
        IO.ANSI.green() <>
          "✓ Enabled SCIM on the Keycloak provider (fixed dev token)" <> IO.ANSI.reset()
      )

    _ ->
      :ok
  end
end

# -- SCIM directory groups + memberships (docker-compose e2e SSO) -----
# Seed a slice of directory state on the Keycloak provider so the SSO connection
# page demonstrates group sync end to end: provisioned identities, the IdP groups
# they belong to (with real member counts), and role mappings for two of the
# three groups (one left unmapped, to show that state in the "Synced groups"
# readout). Uses the real SCIM + mapping entry points, so it exercises the same
# path an IdP + admin would, and is idempotent — re-provisioning/re-upserting
# reconciles, a duplicate mapping is ignored. Gated on the same fixed-dev SCIM
# token as the enablement above, so it runs on any dev/e2e seed (fresh or repeat)
# and never in a prod-style one.
if System.get_env("EMISAR_DEV_FIXED_SCIM_TOKEN") not in [nil, ""] do
  scim_provider =
    case Emisar.SSO.list_providers_for_account(owner_subject) do
      {:ok, providers, _meta} -> Enum.find(providers, & &1.scim_enabled)
      _ -> nil
    end

  if scim_provider do
    scim_people = [
      {"kc|nadia", "nadia@northstar.example", "Nadia Okafor"},
      {"kc|ravi", "ravi@northstar.example", "Ravi Menon"},
      {"kc|lena", "lena@northstar.example", "Lena Fischer"},
      {"kc|theo", "theo@northstar.example", "Theo Alvarez"}
    ]

    for {ext, email, name} <- scim_people do
      {:ok, _} =
        Emisar.SSO.scim_provision_user(scim_provider, %{
          external_id: ext,
          email: email,
          full_name: name
        })
    end

    # {external group id, display, member externalIds, mapped role | nil}
    scim_groups = [
      {"kc-grp-platform", "Platform Engineers", ~w(kc|nadia kc|ravi kc|lena), :admin},
      {"kc-grp-sre", "SRE On-call", ~w(kc|ravi kc|theo), :operator},
      {"kc-grp-security", "Security Review", ~w(kc|nadia), nil}
    ]

    # Map the two mapped groups BEFORE syncing members, so each group sync
    # recomputes its members' roles against the mapping (leave "Security Review"
    # unmapped). A duplicate mapping on a repeat seed is expected — ignore it.
    for {ext, display, _members, role} <- scim_groups, not is_nil(role) do
      case Emisar.SSO.create_group_mapping(
             scim_provider,
             %{
               "external_group_id" => ext,
               "external_group_display" => display,
               "role" => to_string(role)
             },
             owner_subject
           ) do
        {:ok, _} -> :ok
        {:error, _already_mapped} -> :ok
      end
    end

    for {ext, display, members, _role} <- scim_groups do
      {:ok, _} =
        Emisar.SSO.scim_upsert_group(scim_provider, %{
          external_id: ext,
          display: display,
          member_external_ids: members
        })
    end

    IO.puts(
      IO.ANSI.green() <>
        "✓ Seeded SCIM directory: #{length(scim_people)} identities, #{length(scim_groups)} groups" <>
        IO.ANSI.reset()
    )
  end
end

# -- Extra accounts: the plan tiers + an empty one, so the billing / upsell /
#    runner-limit states AND the SSO-is-Enterprise gate are all visible by
#    switching accounts in one seeded dev DB. (The main "demo" account is
#    enterprise — above — so SSO/SCIM is testable there.) -------------------
seed_plan_account = fn name, slug, plan ->
  email = "owner@#{slug}.test"
  full_name = "#{name} Owner"

  owner =
    case Users.fetch_user_by_email(email) do
      {:error, :not_found} ->
        {:ok, u} =
          Users.register_user(%{
            full_name: full_name,
            email: email,
            password: "Sleep-tight-1234"
          })

        u = confirm_user.(u)
        clear_seeded_mfa.(u)

      {:ok, u} ->
        u = ensure_profile.(u, full_name)
        u = confirm_user.(u)
        clear_seeded_mfa.(u)
    end

  acct =
    case Repo.fetch(Account.Query.not_deleted() |> Account.Query.by_slug(slug), Account.Query) do
      {:error, :not_found} ->
        {:ok, a} =
          Accounts.create_account_with_owner(%{name: name, slug: slug}, owner)

        a

      {:ok, a} ->
        a
    end

  {:ok, membership} = Accounts.fetch_membership_for_session(owner, acct.id)
  subject = Subject.for_user(owner, acct, membership)

  acct =
    if acct.name == name do
      acct
    else
      {:ok, updated} = Accounts.update_account(acct, %{name: name}, subject)
      updated
    end

  seed_subscription.(acct, plan)

  subject = Subject.for_user(owner, acct, membership)

  {acct, owner, subject}
end

# Free + Team accounts WITH data (a runner + two finished runs each) so a
# non-enterprise account looks lived-in and its plan's runner limit shows.
for {name, slug, plan} <- [
      {"Acme Logistics Demo", "acme", "free"},
      {"Globex Platform Demo", "globex", "team"}
    ] do
  {acct, owner, subject} = seed_plan_account.(name, slug, plan)

  # Give the paid (Globex/Team) account a Paddle customer so its billing page
  # shows the full self-serve surface — the "Manage subscription" portal button
  # (payment method + plan change) and the inline Recent invoices (the stub
  # PaddleClient serves fake transactions). Free/enterprise accounts have none.
  if plan == "team" do
    acct
    |> Ecto.Changeset.change(paddle_customer_id: "ctm_dev_#{slug}")
    |> Repo.update!()
  end

  runner_name = "#{slug}-prod-1"

  runner =
    case Runners.fetch_runner_by_name(runner_name, subject) do
      {:ok, existing} ->
        existing

      {:error, :not_found} ->
        {:ok, created} =
          insert_seed_runner.(acct.id, %{name: runner_name, group: "prod"})

        created
    end
    |> Ecto.Changeset.change(
      hostname: "#{runner_name}.example",
      labels: %{"env" => "prod", "account" => slug},
      last_connected_at: mins_ago.(35),
      runner_version: "0.4.2"
    )
    |> Repo.update!()

  advertise.(runner, linux_actions)

  existing_account_runs =
    case Runs.list_recent_runs(subject, limit: 1) do
      {:ok, rows, _metadata} -> rows
      _ -> []
    end

  if existing_account_runs == [] do
    for {action, hrs, args, reason} <- [
          {"linux.uptime", 2, %{}, "spot check after runner install"},
          {"linux.disk_usage", 9, %{"paths" => ["/"]}, "daily capacity check"}
        ] do
      {:ok, run} =
        Runs.create_run(%{
          account_id: acct.id,
          runner_id: runner.id,
          action_id: action,
          args: args,
          reason: reason,
          source: "operator",
          requested_by_id: owner.id
        })

      run
      |> Ecto.Changeset.change(
        status: :success,
        inserted_at: hours_ago.(hrs),
        queued_at: hours_ago.(hrs),
        finished_at: DateTime.add(hours_ago.(hrs), 1, :second),
        exit_code: 0,
        duration_ms: 1000
      )
      |> Repo.update!()
    end
  end

  IO.puts(IO.ANSI.cyan() <> "✓ #{name} (slug=#{slug}, #{plan}) — with data" <> IO.ANSI.reset())
end

# An empty Free account — to see the onboarding / empty-state surfaces.
_ = seed_plan_account.("Blank Workspace Demo", "blank", "free")
IO.puts(IO.ANSI.cyan() <> "✓ Blank Workspace Demo (slug=blank, free) — empty" <> IO.ANSI.reset())

# A "both connected, nothing run" account — one runner AND one agent, no runs —
# so the onboarding checklist's third step (the first run, with its example
# prompt) shows without dispatching anything. Demo-owned, reachable by switching
# accounts as demo. Existence-checked, so it just adds the missing agent key to
# the account demo already made by hand rather than duplicating its runner.
both_connected_account =
  case Repo.fetch(
         Account.Query.not_deleted() |> Account.Query.by_slug("both-connected"),
         Account.Query
       ) do
    {:error, :not_found} ->
      {:ok, created} =
        Accounts.create_account_with_owner(
          %{name: "Both Connected Co", slug: "both-connected"},
          user
        )

      created

    {:ok, existing} ->
      existing
  end

{:ok, bc_membership} = Accounts.fetch_membership_for_session(user, both_connected_account.id)
bc_subject = Subject.for_user(user, both_connected_account, bc_membership)

case Runners.list_all_runners_for_account(bc_subject) do
  {:ok, [_ | _]} ->
    :ok

  _ ->
    {:ok, bc_runner} =
      insert_seed_runner.(both_connected_account.id, %{
        name: "both-connected-prod-1",
        group: "prod"
      })

    bc_runner
    |> Ecto.Changeset.change(
      hostname: "both-connected-prod-1.example",
      last_connected_at: mins_ago.(20),
      runner_version: "0.4.2"
    )
    |> Repo.update!()
    |> advertise.(linux_actions)
end

case ApiKeys.list_api_keys_for_account(bc_subject, page: [limit: 10]) do
  {:ok, [_ | _], _} ->
    :ok

  _ ->
    {:ok, _raw, _key} =
      ApiKeys.create_key(
        %{
          name: "Claude Code",
          description: "MCP client for triage"
        },
        bc_subject
      )
end

IO.puts(
  IO.ANSI.cyan() <>
    "✓ Both Connected Co (slug=both-connected) — runner + agent, no runs" <> IO.ANSI.reset()
)
