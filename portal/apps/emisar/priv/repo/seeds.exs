# Seeds for local dev. Run with `mix run apps/emisar/priv/repo/seeds.exs`
# or explicitly via `mix ecto.seed`. Idempotent — safe to re-run.
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
alias Emisar.Billing.Subscription
alias Emisar.Catalog
alias Emisar.Catalog.{PackBaseline, PackVersion}
alias Emisar.Policies
alias Emisar.Repo
alias Emisar.Runbooks
alias Emisar.Runbooks.{ExecutionItem, ExecutionStage, Release, Runbook, RunbookExecution}
alias Emisar.Runbooks.Extractor
alias Emisar.Runners
alias Emisar.Runners.Runner
alias Emisar.Runs
alias Emisar.Runs.ActionRun
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
# Idempotent AND reconciling: upsert refreshes a paid tier, and a free persona
# has its subscription DELETED — so a reseed onto an account that was paid in a
# prior run doesn't leave a stale row that misreports the plan.
seed_subscription = fn %Account{} = account, plan ->
  if plan == "free" do
    Repo.delete_all(Subscription.Query.by_account_id(Subscription.Query.all(), account.id))
  else
    {:ok, _} =
      Billing.upsert_subscription(account.id, %{plan: plan, status: "active"}, manual: true)
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
    otp = NimbleTOTP.verification_code(user.mfa_secret)
    {:ok, updated} = Auth.disable_mfa(otp, %Subject{actor: user})
    updated
end

pack_descriptor = fn pack_id, version ->
  version =
    version || PackBaseline.current_version(pack_id) ||
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

baseline_action_descriptors = fn pack_id ->
  version =
    PackBaseline.current_version(pack_id) ||
      raise "missing current shipped pack version for #{pack_id}"

  hash =
    PackBaseline.lookup(pack_id, version) ||
      raise "missing shipped-pack baseline for #{pack_id} #{version}"

  pack_id
  |> PackBaseline.manifest(version, hash)
  |> get_in(["actions"])
  |> Enum.sort_by(&elem(&1, 0))
  |> Enum.map(fn {action_id, descriptor} ->
    descriptor
    |> Map.drop(["args_schema"])
    |> Map.merge(%{
      "id" => action_id,
      "pack_id" => pack_id,
      "args" => get_in(descriptor, ["args_schema", "args"]) || []
    })
  end)
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

# Every "is this row already here?" lookup below reads the account's WHOLE
# table. A paginated context read would only ever see its first page, and this
# file deliberately seeds each list past one page — so a page-scanning lookup
# stops finding the rows it wrote last time and tries to insert them again,
# which is a unique-violation crash, not a no-op reseed.
account_api_keys = fn ->
  ApiKeys.ApiKey.Query.not_deleted()
  |> ApiKeys.ApiKey.Query.by_account_id(account.id)
  |> Repo.all()
end

peek_account_runbook = fn slug ->
  Runbook.Query.not_deleted()
  |> Runbook.Query.by_account_id(account.id)
  |> Runbook.Query.by_slug(slug)
  |> Repo.peek()
end

# Retire the first-pass demo artifacts so re-running seeds upgrades an existing
# dev DB instead of preserving screenshot-hostile laptop/CI/cache-purge rows.
# Only personas this seed no longer creates belong here. `sam@emisar.dev` was a
# first-pass artifact that later came back as a member-access persona, so
# retiring it deleted the membership the same run re-invites 300 lines below —
# widening Sam's access to `all` and then narrowing it again, which fires the
# session-refresh broadcast against an endpoint `mix run --no-start` never
# started. Every re-seed of a database where Sam had signed in died there.
for email <- ["alex@emisar.dev"] do
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

account_api_keys.()
|> Enum.filter(&(&1.name in ["Claude — Andrew's terminal", "SIEM export — initial"]))
|> Enum.each(fn key ->
  key
  |> Ecto.Changeset.change(deleted_at: now.())
  |> Repo.update!()
end)

case peek_account_runbook.("nightly-edge-health") do
  nil -> :ok
  runbook -> {:ok, _runbook} = Runbooks.delete_runbook(runbook, owner_subject)
end

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
              Accounts.invite_user_to_account(
                %{"email" => email, "role" => role, "runner_access_mode" => "all"},
                owner_subject
              )

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
          Accounts.invite_user_to_account(
            %{"email" => email, "role" => role, "runner_access_mode" => "all"},
            owner_subject
          )

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

# -- Sample runbooks -------------------------------------------------

morning_definition = %{
  "schema_version" => 1,
  "context_markdown" =>
    "## Before you run\n\n- Confirm the morning readiness window.\n- Escalate any failed check before shifting traffic.",
  "inputs" => [],
  "stages" => [
    %{
      "id" => "inspect",
      "title" => "Inspect edge readiness",
      "mode" => "parallel",
      "max_parallel" => 3,
      "steps" => [
        %{
          "id" => "uptime",
          "pack" => %{"id" => "linux-core"},
          "action" => "linux.uptime",
          "targets" => %{"selection" => "all", "refs" => ["group:edge-web"]},
          "args" => %{},
          "outputs" => [],
          "success" => [],
          "wait" => nil
        },
        %{
          "id" => "disk",
          "pack" => %{"id" => "linux-core"},
          "action" => "linux.disk_usage",
          "targets" => %{"selection" => "all", "refs" => ["group:edge-web"]},
          "args" => %{},
          "outputs" => [],
          "success" => [],
          "wait" => nil
        },
        %{
          "id" => "memory",
          "pack" => %{"id" => "linux-core"},
          "action" => "linux.memory",
          "targets" => %{"selection" => "all", "refs" => ["group:edge-web"]},
          "args" => %{},
          "outputs" => [],
          "success" => [],
          "wait" => nil
        }
      ]
    }
  ]
}

morning_attrs = %{
  slug: "morning-edge-readiness",
  title: "Morning edge readiness",
  description:
    "08:00 UTC check across the edge-web group before the EU traffic peak: " <>
      "host load, disk pressure, and memory health.",
  draft_definition: morning_definition
}

# Publication is arranged at the changeset level: the demo runners these
# runbooks target are seeded further down, so the context's current-state
# publication readiness cannot pass yet.
publish_seeded_runbook = fn %Runbook{} = runbook ->
  definition = runbook.draft_definition
  version = (runbook.live_version || 0) + 1

  {:ok, _release} =
    Release.Changeset.create(%{
      account_id: runbook.account_id,
      runbook_id: runbook.id,
      version: version,
      title: runbook.title,
      description: runbook.description,
      definition: definition,
      definition_sha256: Runbooks.definition_digest(definition),
      published_by_id: runbook.created_by_id
    })
    |> Repo.insert()

  {:ok, published} =
    runbook
    |> Runbook.Changeset.publish(definition, version)
    |> Repo.update()

  published
end

seed_live_runbook = fn slug, attrs ->
  runbook =
    case peek_account_runbook.(slug) do
      nil ->
        {:ok, created} = account.id |> Runbook.Changeset.create(user.id, attrs) |> Repo.insert()
        created

      existing ->
        {:ok, updated} = existing |> Runbook.Changeset.draft(attrs) |> Repo.update()
        updated
    end

  # Republish only when the seeded definition actually moved; a plain reseed
  # keeps v1 rather than minting a release nobody authored.
  if runbook.draft_definition == runbook.definition do
    {:ok, unchanged} = runbook |> Runbook.Changeset.discard_draft() |> Repo.update()
    unchanged
  else
    publish_seeded_runbook.(runbook)
  end
end

morning_runbook = seed_live_runbook.("morning-edge-readiness", morning_attrs)

IO.puts(IO.ANSI.cyan() <> "✓ Seeded empty-history sample runbook" <> IO.ANSI.reset())

approval_definition = %{
  "schema_version" => 1,
  "context_markdown" =>
    "## Change window\n\n" <>
      "- Confirm the candidate config has passed `caddy validate`.\n" <>
      "- Keep the incident channel open while both edge nodes reload.\n\n" <>
      "## Rollback\n\n" <>
      "Restore the previous config and run this runbook again with its path.",
  "inputs" => [
    %{
      "id" => "config_path",
      "description" => "Absolute path to the validated Caddy configuration.",
      "type" => "string",
      "required" => false,
      "sensitive" => false,
      "default" => "/etc/caddy/Caddyfile",
      "min_length" => 1,
      "max_length" => 256
    }
  ],
  "stages" => [
    %{
      "id" => "reload",
      "title" => "Reload edge configuration",
      "mode" => "parallel",
      "max_parallel" => 2,
      "steps" => [
        %{
          "id" => "reload_caddy",
          "pack" => %{"id" => "caddy"},
          "action" => "caddy.reload_config",
          "targets" => %{"selection" => "all", "refs" => ["group:edge-web"]},
          "args" => %{
            "file" => %{"source" => "input", "ref" => "config_path"}
          },
          "outputs" => [],
          "success" => [],
          "wait" => nil
        }
      ]
    },
    %{
      "id" => "verify",
      "title" => "Verify the edge fleet",
      "mode" => "parallel",
      "max_parallel" => 2,
      "steps" => [
        %{
          "id" => "check_version",
          "pack" => %{"id" => "caddy"},
          "action" => "caddy.version",
          "targets" => %{"selection" => "random_one", "refs" => ["group:edge-web"]},
          "args" => %{},
          "outputs" => [],
          "success" => [],
          "wait" => nil
        },
        %{
          "id" => "check_upstreams",
          "pack" => %{"id" => "caddy"},
          "action" => "caddy.reverse_proxy_upstreams",
          "targets" => %{"selection" => "all", "refs" => ["group:edge-web"]},
          "args" => %{},
          "outputs" => [
            %{
              "id" => "healthy",
              "source" => "structured_output",
              "sensitive" => false,
              "extract" => %{"type" => "json_pointer", "expression" => "/healthy"}
            }
          ],
          "success" => [
            %{"output" => "healthy", "operator" => "equals", "value" => true}
          ],
          "wait" => %{
            "interval_seconds" => 10,
            "timeout_seconds" => 120,
            "max_attempts" => 12
          }
        }
      ]
    }
  ]
}

approval_attrs = %{
  slug: "edge-configuration-rollout",
  title: "Edge configuration rollout",
  description:
    "Reload a validated Caddy configuration across the edge fleet, " <>
      "then verify the running version and upstream health.",
  draft_definition: approval_definition
}

approval_runbook = seed_live_runbook.("edge-configuration-rollout", approval_attrs)

# The guide follows this one procedure end to end, so the unpublished change it
# documents lives here: reload the two edge nodes one at a time instead of
# together. ONE scalar edit on purpose — the published diff has to be legible in
# a docs screenshot, and a JSON line diff cannot wrap, so editing a long string
# value (context_markdown) produces a truncated pair that shows the reader
# nothing.
approval_draft_definition =
  put_in(approval_definition, ["stages", Access.at(0), "max_parallel"], 1)

{:ok, _approval_draft} =
  approval_runbook
  |> Runbook.Changeset.draft(%{draft_definition: approval_draft_definition})
  |> Repo.update()

IO.puts(IO.ANSI.cyan() <> "✓ Seeded edge configuration rollout runbook" <> IO.ANSI.reset())

# The approvals queue is FIFO, so its filler has to be NEWER than the curated
# requests to leave them on page one — and a request dispatched at seed time is
# newest by construction. A runbook execution awaiting approval creates no
# action runs, so this backlog adds pages to Approvals without touching the runs
# list. Titled past "Morning edge readiness" so the runbooks list keeps its two
# curated rows first (see the pagination volume section at the end of the file).
backlog_attrs = %{
  slug: "rotate-edge-tls-certificates",
  title: "Rotate edge TLS certificates",
  description:
    "Reload the edge fleet onto freshly issued certificates. Every run waits " <>
      "for an approver, which is what keeps a visible backlog on this account.",
  draft_definition: approval_definition
}

backlog_runbook = seed_live_runbook.("rotate-edge-tls-certificates", backlog_attrs)

IO.puts(IO.ANSI.cyan() <> "✓ Seeded edge TLS rotation runbook" <> IO.ANSI.reset())

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
  case Runners.fetch_runner_by_name(spec.name, owner_subject) do
    {:ok, existing} ->
      existing
      |> Ecto.Changeset.change(
        external_id: spec.external_id,
        group: spec.group,
        labels: spec.labels
      )
      |> Repo.update!()

    {:error, :not_found} ->
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

edge_actions = baseline_action_descriptors.("caddy")

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
    "risk" => "high",
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

# The demo fleet runs one version behind on postgres so the packs page shows the
# quiet pack-level "update available" nudge. DERIVED, not pinned: the literal
# that used to sit here would have broken the seed the day its version left the
# trust window ("missing shipped-pack baseline"). Only the data-postgres runner
# advertises postgres, and a windowed previous version is baseline-trusted with
# no retirement watermark, so it dispatches fine — the hint is a convenience, not
# a block. Every other pack advertises at its current shipped version. Keep the
# fleet strictly behind or the nudge correctly suppresses: you have the latest.
#
# nil (a pack whose window holds only the current version) falls through to the
# current version in pack_descriptor, which simply means no nudge that run.
pack_version_overrides = %{"postgres" => PackBaseline.previous_version("postgres")}

advertise = fn runner, actions ->
  packs =
    actions
    |> Enum.map(& &1["pack_id"])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Map.new(fn pack_id ->
      {pack_id, pack_descriptor.(pack_id, pack_version_overrides[pack_id])}
    end)

  payload = %{
    "hostname" => runner.hostname,
    "labels" => runner.labels || %{},
    "version" => runner.runner_version,
    "packs" => packs,
    "actions" => actions
  }

  # A runner that is CONNECTED right now owns its own advertisement, and it sends
  # the real pack descriptors — side effects, examples, the lot. These fixtures
  # are thin by comparison, so advertising over a live runner on a warm
  # `compose up` replaces rich rows with poor ones. The catalog then disagrees
  # with the trusted manifest until the runner re-advertises, and for that window
  # `list_packs` comes back empty and `get_action` answers action_unavailable.
  #
  # Seeds exist to furnish an EMPTY environment, so skip any runner that already
  # has an advertisement. A fresh stack still gets the full demo catalog.
  already_advertised? =
    Catalog.RunnerAction.Query.all()
    |> Catalog.RunnerAction.Query.by_runner_id(runner.id)
    |> Repo.exists?()

  if already_advertised? do
    :ok
  else
    {:ok, _} = Catalog.observe_state(runner, payload)
  end
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

IO.puts(
  IO.ANSI.cyan() <>
    "✓ Advertised actions on every runner (postgres one version behind → update-available hint)" <>
    IO.ANSI.reset()
)

# -- Member access shapes ---------------------------------------------
#
# The roster is where a grant has to READ correctly, so seed one member per
# shape it can take: every runner, a group plus one exact host, several groups
# narrowed to named packs, and every runner narrowed to a single pack. Runs
# after the catalog because a pack selection is allowlisted against the pack ids
# the account actually carries.

{:ok, scope_runners} = Runners.list_all_runners_for_account(owner_subject)
{:ok, scope_packs} = Catalog.list_account_pack_ids(owner_subject)
scope_allowlist = Accounts.runner_access_allowlist(scope_runners, scope_packs)

runner_ref = fn name ->
  case Enum.find(scope_runners, &(&1.name == name)) do
    nil -> raise "seed runner #{name} is missing — member access shapes seed after the fleet"
    runner -> "runner:" <> runner.id
  end
end

set_member_access = fn %User{} = member, mode, scope, pack_mode, pack_scope ->
  membership = Accounts.peek_sync_membership(account.id, member.id)

  {:ok, access} =
    Accounts.build_runner_access(mode, scope, scope_allowlist, pack_mode, pack_scope)

  {:ok, _membership} =
    Accounts.update_membership_runner_access(membership, access, owner_subject)
end

# A group plus one exact host from a different group — the shape a picker
# collapses wrongly if it lets a group and its own members both be checked.
set_member_access.(priya, "restricted", ["group:edge-web", runner_ref.("api-iad-02")], "all", [])

sam = invite_member.("sam@emisar.dev", "Sam Okafor", "operator")

set_member_access.(
  sam,
  "restricted",
  ["group:edge-web", "group:data-postgres"],
  "restricted",
  ["pack:linux-core", "pack:postgres"]
)

# Every runner, one pack: the "may look at Postgres anywhere, may not open a
# shell" grant that runner groups alone cannot express.
wren = invite_member.("wren@emisar.dev", "Wren Alvarez", "viewer")
set_member_access.(wren, "all", [], "restricted", ["pack:postgres"])

IO.puts(
  IO.ANSI.cyan() <>
    "✓ Member access shapes: Jordan (all), Priya (group + host), Sam (2 groups, 2 packs), Wren (all runners, 1 pack)" <>
    IO.ANSI.reset()
)

# -- Runbook execution history + whole-run approval ------------------
#
# The readiness runbook intentionally stays empty. The rollout runbook carries
# one success, one denied execution, and one current whole-plan approval so the
# console's empty, history, and pending states are all visible after one reset.
# These rows are demo fixtures, so rerunning seeds replaces only this runbook's
# executions instead of accumulating another story.

Enum.each([approval_runbook, backlog_runbook], fn runbook ->
  RunbookExecution.Query.by_runbook_id(runbook.id)
  |> Repo.all()
  |> Enum.each(fn execution ->
    ActionRun.Query.all()
    |> ActionRun.Query.by_runbook_execution_id(execution.id)
    |> Repo.delete_all()
  end)

  RunbookExecution.Query.by_runbook_id(runbook.id)
  |> Repo.delete_all()
end)

temporary_connections =
  runners
  |> Enum.filter(&(&1.group == "edge-web"))
  |> Enum.flat_map(fn runner ->
    if Runners.online?(account.id, runner.id) do
      []
    else
      case Runners.connect_runner(runner) do
        {:ok, connected} -> [connected]
        {:error, :already_connected} -> []
      end
    end
  end)

fetch_execution_request = fn execution_id ->
  ApprovalRequest.Query.all()
  |> ApprovalRequest.Query.by_runbook_execution_id(execution_id)
  |> Repo.one!()
end

dispatch_seed_execution = fn %Runbook{} = runbook, reason ->
  {:ok, %{execution_id: execution_id, runs: []}} =
    Runbooks.dispatch_runbook(runbook, reason, owner_subject)

  %RunbookExecution{status: :pending_approval} =
    RunbookExecution.Query.by_id(execution_id)
    |> Repo.one!()

  execution_id
end

jordan_membership = Accounts.peek_sync_membership(account.id, jordan.id)
jordan_subject = Subject.for_user(jordan, account, jordan_membership)

# One reason per region and cause, so the queue reads as real work rather than
# the same sentence 36 times. 36 + the curated request fills three pages of the
# 15-row queue.
backlog_reasons =
  for region <- ~w[eu-central us-east-1 us-west-2 ap-south-1 sa-east-1 eu-west-2],
      cause <- [
        "the 90-day certificate window closes on Sunday",
        "the upstream intermediate CA was rotated",
        "the wildcard leaf was reissued after the SAN change",
        "the ACME account key was migrated to the new provider",
        "the staged renewal never reloaded after the deploy",
        "the expiry monitor opened a ticket for this region"
      ],
      do: "Rotate the #{region} edge certificates - #{cause}."

seeded_execution_ids =
  try do
    succeeded_id =
      dispatch_seed_execution.(
        approval_runbook,
        "Reload the validated Caddyfile during the completed Tuesday maintenance window."
      )

    halted_id =
      dispatch_seed_execution.(
        approval_runbook,
        "Reload the edge configuration before the change window has opened."
      )

    halted_request = fetch_execution_request.(halted_id)

    {:ok, {%ApprovalRequest{status: :denied}, :runbook_execution}} =
      Approvals.deny_request(
        halted_request,
        jordan_subject,
        "Wait for the approved change window."
      )

    pending_id =
      dispatch_seed_execution.(
        approval_runbook,
        "Roll out the validated Caddyfile during the scheduled edge maintenance window."
      )

    backlog_ids =
      Enum.map(backlog_reasons, &dispatch_seed_execution.(backlog_runbook, &1))

    %{succeeded: succeeded_id, halted: halted_id, pending: pending_id, backlog: backlog_ids}
  after
    Enum.each(temporary_connections, fn connected ->
      {:ok, disconnected} =
        Runners.disconnect_runner(
          connected.id,
          connected.connection_generation,
          connected.connection_lease_id,
          "seed preflight complete"
        )

      spec = Enum.find(runner_specs, &(&1.name == disconnected.name))
      stamp_runner_state.(disconnected, spec)
    end)
  end

# The queue only paginates while its rows are still pending, and
# `Approvals.expire_overdue_requests/1` flips anything past `expires_at`. The
# policy's 24h window is why this account's curated pending approvals decayed to
# one over a few days; the backlog carries a change-freeze-length window instead
# so the pages survive until the next reseed.
backlog_expires_at = DateTime.add(now.(), 21 * 86_400, :second)

Enum.each(seeded_execution_ids.backlog, fn execution_id ->
  ApprovalRequest.Query.all()
  |> ApprovalRequest.Query.by_runbook_execution_id(execution_id)
  |> Repo.update_all(set: [expires_at: backlog_expires_at])
end)

backdate_execution = fn execution_id, timestamp ->
  RunbookExecution.Query.by_id(execution_id)
  |> Repo.one!()
  |> Ecto.Changeset.change(inserted_at: timestamp, updated_at: timestamp)
  |> Repo.update!()

  ExecutionStage.Query.by_execution_id(execution_id)
  |> Repo.update_all(set: [inserted_at: timestamp, updated_at: timestamp])

  ExecutionItem.Query.by_execution_id(execution_id)
  |> Repo.update_all(set: [inserted_at: timestamp, updated_at: timestamp])

  ApprovalRequest.Query.all()
  |> ApprovalRequest.Query.by_runbook_execution_id(execution_id)
  |> Repo.update_all(
    set: [
      requested_at: timestamp,
      expires_at: DateTime.add(timestamp, 24 * 3600, :second),
      inserted_at: timestamp,
      updated_at: timestamp
    ]
  )
end

succeeded_at = hours_ago.(4)
succeeded_finished_at = DateTime.add(succeeded_at, 18, :second)
succeeded_request = fetch_execution_request.(seeded_execution_ids.succeeded)

succeeded_request
|> Ecto.Changeset.change(
  status: :approved,
  decided_by_id: jordan.id,
  decided_at: DateTime.add(succeeded_at, 5, :second),
  decision_reason: "Validated config, drained connections, and an open change window."
)
|> Repo.update!()

ExecutionItem.Query.by_execution_id(seeded_execution_ids.succeeded)
|> Repo.all()
|> Enum.each(fn item ->
  {outputs, outputs_raw, outputs_sha256, evidence} =
    if item.output_plan == [] and item.success_plan == [] do
      {%{}, nil, nil, []}
    else
      {:ok, result} =
        Extractor.evaluate_materialized(
          item.output_plan,
          item.success_plan,
          %{
            "structured_output" => %{"healthy" => true, "upstreams" => 2},
            "stdout" => "{\"healthy\":true,\"upstreams\":2}\n",
            "stderr" => ""
          }
        )

      raw = Jason.encode!(result.raw)
      digest = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
      {result.public, raw, digest, result.evidence}
    end

  item
  |> ExecutionItem.Changeset.succeed(
    outputs,
    outputs_raw,
    outputs_sha256,
    evidence,
    succeeded_finished_at
  )
  |> Ecto.Changeset.change(
    attempt_count: 1,
    started_at: DateTime.add(succeeded_at, 6, :second)
  )
  |> Repo.update!()
end)

ExecutionStage.Query.by_execution_id(seeded_execution_ids.succeeded)
|> Repo.all()
|> Enum.each(fn stage ->
  stage
  |> ExecutionStage.Changeset.succeed(succeeded_finished_at)
  |> Ecto.Changeset.change(started_at: DateTime.add(succeeded_at, 6, :second))
  |> Repo.update!()
end)

RunbookExecution.Query.by_id(seeded_execution_ids.succeeded)
|> Repo.one!()
|> RunbookExecution.Changeset.succeed(succeeded_finished_at)
|> Repo.update!()

backdate_execution.(seeded_execution_ids.succeeded, succeeded_at)
halted_at = days_ago.(1)
halted_finished_at = DateTime.add(halted_at, 3, :second)
backdate_execution.(seeded_execution_ids.halted, halted_at)

RunbookExecution.Query.by_id(seeded_execution_ids.halted)
|> Repo.update_all(
  set: [
    halted_at: halted_finished_at,
    completed_at: halted_finished_at,
    updated_at: halted_finished_at
  ]
)

ExecutionStage.Query.by_execution_id(seeded_execution_ids.halted)
|> Repo.update_all(set: [finished_at: halted_finished_at, updated_at: halted_finished_at])

ExecutionItem.Query.by_execution_id(seeded_execution_ids.halted)
|> Repo.update_all(set: [finished_at: halted_finished_at, updated_at: halted_finished_at])

ApprovalRequest.Query.all()
|> ApprovalRequest.Query.by_runbook_execution_id(seeded_execution_ids.halted)
|> Repo.update_all(set: [decided_at: halted_finished_at, updated_at: halted_finished_at])

backdate_execution.(seeded_execution_ids.pending, mins_ago.(8))

%ApprovalRequest{status: :pending} =
  fetch_execution_request.(seeded_execution_ids.pending)

IO.puts(
  IO.ANSI.cyan() <>
    "✓ Seeded runbook empty state, execution history, and whole-run approval" <>
    IO.ANSI.reset()
)

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

agent_key_name = "Claude Code"

agent_key_attrs = %{
  name: agent_key_name,
  description:
    "MCP bridge used by the on-call engineer for read-only triage and " <>
      "approval-gated remediation."
}

agent_key = Enum.find(account_api_keys.(), &(&1.name == agent_key_name))

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
    # What Claude Code actually reports at `initialize` (clientInfo) plus the
    # emisar-mcp bridge version the portal reads off the UA — not a hand-faked
    # label. name is the machine id, title the human one, version the client's
    # own release, bridge_version the stdio bridge's.
    last_client_info: %{
      "name" => "claude-code",
      "title" => "Claude Code",
      "version" => "2.1.4",
      "bridge_version" => "0.3.4"
    }
  )
  |> Repo.update!()

IO.puts(IO.ANSI.cyan() <> "✓ Seeded MCP API key for the LLM agent" <> IO.ANSI.reset())

# -- A realistic agent fleet ----------------------------------------
#
# More MCP keys so the agents page shows the spread operators really see:
# different clients (each reports its own clientInfo at `initialize`),
# different owners (the list groups by the issuing human), a range of
# liveness states, a stale bridge that earns the upgrade prompt, and a
# rotation still mid-swap. Built directly (§7 seed style) and idempotent by
# (name, owner) so re-seeding converges the state instead of duplicating.
#
# Bridge-version policy in dev (config/config.exs): supported at >= 0.3.0,
# below that unsupported. `current` reads clean; `stale` earns the
# "unsupported" chip on its row and the fleet-wide upgrade notice.
mcp_bridge_current = "0.3.4"
mcp_bridge_stale = "0.2.7"

jordan_membership = Accounts.peek_sync_membership(account.id, jordan.id)
days_out = &DateTime.add(now.(), &1 * 86_400, :second)

# Build (or converge) one agent key directly under a given member. Idempotent
# by (name, owner): a re-seed updates the liveness/client state rather than
# minting a duplicate. `client_info` mirrors what that client's `initialize`
# records; `used_at`/`expires_at` set the row's liveness the way real calls do.
seed_agent_key = fn owner_user, owner_membership_id, name, client_info, used_at, expires_at ->
  existing =
    Enum.find(account_api_keys.(), &(&1.name == name and &1.created_by_id == owner_user.id))

  key =
    existing ||
      (
        {_raw, prefix, hash} = Emisar.Crypto.mint("emk-", 12)

        {:ok, minted} =
          ApiKeys.ApiKey.Changeset.create(
            account.id,
            owner_user.id,
            owner_membership_id,
            prefix,
            hash,
            %{name: name}
          )
          |> Repo.insert()

        minted
      )

  key
  |> Ecto.Changeset.change(
    last_used_at: used_at,
    last_client_info: client_info,
    expires_at: expires_at,
    revoked_at: nil
  )
  |> Repo.update!()
end

# {owner, membership_id, key name, client_info, last_used_at, expires_at}
[
  # A pure quick-mint: named after its client, so the list DROPS the redundant
  # "client Claude Code" seg — the name already says which client it is.
  {user, owner_membership.id, "Claude Code",
   %{
     "name" => "claude-code",
     "title" => "Claude Code",
     "version" => "2.1.4",
     "bridge_version" => mcp_bridge_current
   }, mins_ago.(3), days_out.(30)},
  # Remote OAuth (ChatGPT): it initialized — so it reports a client — but no
  # tracked call has landed yet → "never used". No bridge (remote), and OAuth
  # owns its lifecycle so there is no static expiry.
  {user, owner_membership.id, "ChatGPT", %{"name" => "openai-mcp (ChatGPT)"}, nil, nil},
  # A second owner's key, so the list gains a second owner group. Codex reports
  # a short "Codex" title that differs from the key name → the client seg stays.
  {jordan, jordan_membership.id, "Codex CLI",
   %{"name" => "Codex", "version" => "0.9.2", "bridge_version" => mcp_bridge_current},
   mins_ago.(6), days_out.(30)},
  # A stale bridge → the rose "unsupported" chip on the row AND the page-level
  # "MCP bridge update" notice with the install command.
  {jordan, jordan_membership.id, "Gemini CLI",
   %{"name" => "gemini-cli-mcp-client", "bridge_version" => mcp_bridge_stale}, hours_ago.(1),
   days_out.(29)},
  # Drift: a key named for one client but actually driven by another (Claude
  # Code), gone quiet for weeks → dormant. Here the client seg earns its place —
  # the name alone would mislead.
  {jordan, jordan_membership.id, "Claude Desktop",
   %{"name" => "claude-code", "title" => "Claude Code", "bridge_version" => mcp_bridge_current},
   days_ago.(17), days_out.(13)}
]
|> Enum.each(fn {owner_user, membership_id, name, client_info, used_at, expires_at} ->
  seed_agent_key.(owner_user, membership_id, name, client_info, used_at, expires_at)
end)

# A rotation still mid-swap: the operator rotated "Cursor", so a successor
# exists, but its first call hasn't landed — the predecessor keeps working until
# it does. The list shows the successor's amber "replaces … · swap pending".
cursor_keys =
  Enum.filter(account_api_keys.(), &(&1.name == "Cursor" and &1.created_by_id == user.id))

cursor_client = %{"name" => "cursor", "bridge_version" => mcp_bridge_current}

cursor_predecessor =
  Enum.find(cursor_keys, &is_nil(&1.replaces_id)) ||
    (
      {_raw, prefix, hash} = Emisar.Crypto.mint("emk-", 12)

      {:ok, minted} =
        ApiKeys.ApiKey.Changeset.create(
          account.id,
          user.id,
          owner_membership.id,
          prefix,
          hash,
          %{name: "Cursor"}
        )
        |> Repo.insert()

      minted
    )

cursor_predecessor =
  cursor_predecessor
  |> Ecto.Changeset.change(
    last_used_at: days_ago.(2),
    last_client_info: cursor_client,
    expires_at: days_out.(20),
    revoked_at: nil
  )
  |> Repo.update!()

cursor_successor =
  Enum.find(cursor_keys, &(not is_nil(&1.replaces_id))) ||
    (
      {_raw, prefix, hash} = Emisar.Crypto.mint("emk-", 12)

      {:ok, minted} =
        ApiKeys.ApiKey.Changeset.create(
          account.id,
          user.id,
          owner_membership.id,
          prefix,
          hash,
          %{name: "Cursor"},
          replaces_id: cursor_predecessor.id,
          credential_lineage_id: cursor_predecessor.credential_lineage_id
        )
        |> Repo.insert()

      minted
    )

# Successor never used yet (nil last_used_at) → the swap stays pending; the
# predecessor points at it so the pair reads as one in-flight rotation.
cursor_successor
|> Ecto.Changeset.change(
  last_used_at: nil,
  last_client_info: cursor_client,
  expires_at: days_out.(30),
  revoked_at: nil
)
|> Repo.update!()

cursor_predecessor
|> Ecto.Changeset.change(rotated_to_id: cursor_successor.id)
|> Repo.update!()

IO.puts(
  IO.ANSI.cyan() <>
    "✓ Seeded the agent fleet (multiple clients + owners, a stale bridge, a mid-swap rotation)" <>
    IO.ANSI.reset()
)

# -- Audit-export key ------------------------------------------------
#
# Mirrors the "Mint export token" button on the audit page so a
# freshly-seeded demo account already shows what the SIEM workflow
# looks like — a separate token on the audit page whose `:audit_export`
# kind can reach only the read-only audit endpoint.

export_key_name = "SIEM export - Datadog intake"

export_key = Enum.find(account_api_keys.(), &(&1.name == export_key_name))

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

# The release seeder runs beside the live portal, whose timeout worker correctly
# settles visible in-flight runs while the demo runners are still offline. Keep
# each synthetic running -> terminal history write inside one transaction so a
# background sweep can only observe the finished fixture.
seed_terminal_history = fn seed_fun ->
  {:ok, run} = Repo.transaction(seed_fun)
  run
end

existing_runs =
  case Runs.list_recent_runs(owner_subject, limit: 1) do
    {:ok, list, _meta} -> list
    _ -> []
  end

if existing_runs == [] do
  # A live dispatch snapshots the pack contract on the run (pack_ref +
  # expected_pack_hash); the approve-time trust recheck compares the CURRENT
  # catalog hash against that snapshot, so a pending run seeded without one
  # can never be approved (the /security screencast take approves one live).
  # Stamp from the advertised catalog row directly — the seeded advertisement
  # carries the same baseline hash a live runner re-advertises, and the strict
  # dispatch resolver is the APPROVER's gate, not the seeder's. A non-catalog
  # action (nothing advertised) stays snapshot-free like a legacy run.
  contract_attrs = fn runner_id, action_id ->
    with {:ok, action} <- Catalog.fetch_action_for_account(action_id, runner_id, account.id),
         true <-
           is_binary(action.pack_id) and is_binary(action.pack_version) and
             is_binary(action.pack_hash),
         {:ok, pack_ref} <-
           Catalog.MCPProjection.pack_ref(action.pack_id, action.pack_version, action.pack_hash) do
      %{pack_ref: pack_ref, expected_pack_hash: action.pack_hash}
    else
      _ -> %{}
    end
  end

  insert_run = fn attrs ->
    {:ok, run} =
      contract_attrs.(attrs.runner_id, attrs.action_id)
      |> Map.merge(attrs)
      |> Map.merge(%{
        account_id: account.id,
        source: attrs[:source] || "operator",
        requested_by_id: attrs[:requested_by_id] || user.id,
        policy_id: policy && policy.id,
        policy_decision: attrs[:policy_decision] || "allow",
        policy_reason:
          attrs[:policy_reason] || "The account policy allows low-risk actions by default."
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

  # `finished_at` may come from the caller (a backdated run) — the audit row is
  # stamped at that same moment so the demo audit timeline matches the runs it
  # records instead of bunching every event at seed time.
  persist_terminal_run = fn run, status, attrs ->
    changeset =
      ActionRun.Changeset.transition(run, status, Map.put_new(attrs, :finished_at, now.()))

    {:ok, %{run: run}} =
      Ecto.Multi.new()
      |> Ecto.Multi.update(:run, changeset)
      |> Ecto.Multi.run(:audit, fn repo, %{run: run} ->
        run
        |> Audit.run_event_changeset()
        |> Ecto.Changeset.change(occurred_at: run.finished_at)
        |> repo.insert()
      end)
      |> Repo.commit_multi()

    run
  end

  backdate_request = fn request, requested_at ->
    request
    |> Ecto.Changeset.change(
      requested_at: requested_at,
      expires_at: DateTime.add(requested_at, 24 * 3600, :second)
    )
    |> Repo.update!()
  end

  # `Runs.create_run` writes the `action_run.pending_approval` hold row at seed
  # time; move it back to the request's claimed moment so the audit timeline
  # stays causally ordered (awaiting -> decided -> terminal).
  backdate_dispatch_audit = fn run, occurred_at ->
    Audit.Event.Query.all()
    |> Repo.all()
    |> Enum.filter(&(&1.request_id == run.request_id))
    |> Enum.each(fn event ->
      event |> Ecto.Changeset.change(occurred_at: occurred_at) |> Repo.update!()
    end)
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

    run =
      persist_terminal_run.(run, :success, %{
        finished_at: finished_at,
        exit_code: 0,
        duration_ms: duration_ms,
        emitted_stdout_bytes: chunks_bytes.(chunks, "stdout"),
        emitted_stderr_bytes: chunks_bytes.(chunks, "stderr"),
        emitted_stdout_sha256: chunks_sha.(chunks, "stdout"),
        emitted_stderr_sha256: chunks_sha.(chunks, "stderr"),
        output_complete: true,
        event_id: "seed-" <> Ecto.UUID.generate()
      })

    run
    |> Ecto.Changeset.change(sent_at: DateTime.add(finished_at, -duration_ms, :millisecond))
    |> Repo.update!()
  end

  finalize_failure = fn run, finished_at, exit_code, reason, chunks ->
    append_chunks.(run, chunks)

    persist_terminal_run.(run, :failed, %{
      finished_at: finished_at,
      exit_code: exit_code,
      duration_ms: 4500,
      error_message: reason,
      emitted_stdout_bytes: chunks_bytes.(chunks, "stdout"),
      emitted_stderr_bytes: chunks_bytes.(chunks, "stderr"),
      emitted_stdout_sha256: chunks_sha.(chunks, "stdout"),
      emitted_stderr_sha256: chunks_sha.(chunks, "stderr"),
      output_complete: true,
      event_id: "seed-" <> Ecto.UUID.generate()
    })
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

  # Timestamp-free on purpose: the approved-story run is re-dated relative to
  # each seed, and a hardcoded date inside the log lines would contradict it.
  caddy_reload_stdout = [
    {"stdout", "INFO using adjacent Caddyfile\n"},
    {"stdout", "INFO autosaved config\n"},
    {"stdout", "INFO serving initial configuration\n"}
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

    seed_terminal_history.(fn ->
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
  end)

  Enum.each(agent_runs, fn {runner, action_id, started_at, dur_ms, args, reason, chunks} ->
    finished_at = DateTime.add(started_at, dur_ms, :millisecond)

    seed_terminal_history.(fn ->
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
  end)

  # A single old failure for filters/detail screenshots. It is outside the
  # dashboard's 24h headline so the default account reads healthy.
  failed_specs = [
    {edge, "caddy.validate_config", days_ago.(5), 1, "config validation failed before reload",
     %{"file" => "/etc/caddy/Caddyfile"}, jordan, caddy_validate_failure}
  ]

  Enum.each(failed_specs, fn {runner, action_id, started_at, exit_code, reason, args, who, chunks} ->
    finished_at = DateTime.add(started_at, 4500, :millisecond)

    seed_terminal_history.(fn ->
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
  end)

  # One old cancelled run. It gives the Runs filters a realistic terminal
  # non-error without putting a fresh warning on the dashboard.
  cancelled_at = days_ago.(3)

  seed_terminal_history.(fn ->
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

    cancelled
    |> persist_terminal_run.(:cancelled, %{
      finished_at: cancelled_at,
      cancelled_at: cancelled_at
    })
    |> Ecto.Changeset.change(reason_text: "operator cancelled - rollback already completed")
    |> Repo.update!()
  end)

  IO.puts(
    IO.ANSI.cyan() <>
      "✓ Seeded #{length(successes) + length(agent_runs)} recent successes (#{length(agent_runs)} via MCP agent), 1 old failure, 1 old cancellation" <>
      IO.ANSI.reset()
  )

  # -- Pending approvals (so dashboard "Needs attention" lights up) ---
  #
  # Mix of human-initiated + agent-initiated requests so the approvals
  # page shows both shapes. Claude (the MCP agent) asks for the caddy
  # reload — the same recurring action the approved story below already
  # ran, so the /security screencast frames read as one continuous loop —
  # and Priya files the high-risk restart herself.

  # The decider for the approved/denied stories below. Their audit rows are
  # seeded through the same `Audit.Events` builders the real approve/deny
  # flow uses, so the demo audit shows the complete trail
  # (awaiting -> decided -> terminal), not just the hold.
  jordan_subject = Subject.for_user(jordan, account, jordan_membership)

  pending1_at = mins_ago.(6)

  pending1 =
    insert_run.(%{
      runner_id: edge.id,
      action_id: "caddy.reload_config",
      args: %{"file" => "/etc/caddy/Caddyfile"},
      reason: "Maya via Claude: apply the checked-in Caddyfile after certificate renewal",
      requested_by_id: user.id,
      source: "mcp",
      api_key_id: agent_key.id,
      status: "pending_approval",
      requires_approval: true,
      policy_decision: "require_approval",
      policy_reason: "The account policy requires approval for high-risk actions by default."
    })
    |> backdate.(pending1_at)

  {:ok, req1} =
    Approvals.create_request(
      pending1,
      user.id,
      "Config was validated in CI; needs an admin approval before the edge reload."
    )

  backdate_request.(req1, pending1_at)
  backdate_dispatch_audit.(pending1, pending1_at)

  pending2_at = mins_ago.(22)

  pending2 =
    insert_run.(%{
      runner_id: api.id,
      action_id: "systemd.unit_restart",
      args: %{"unit" => "checkout-api.service"},
      reason: "restart checkout-api after deploy smoke test",
      requested_by_id: priya.id,
      status: "pending_approval",
      requires_approval: true,
      policy_decision: "require_approval",
      policy_reason: "The account policy requires approval for high-risk actions by default."
    })
    |> backdate.(pending2_at)

  {:ok, req2} =
    Approvals.create_request(
      pending2,
      priya.id,
      "Smoke test is green - needs the deploy captain's sign-off before the restart."
    )

  backdate_request.(req2, pending2_at)
  backdate_dispatch_audit.(pending2, pending2_at)

  # The approved-and-executed story: requested by the agent, approved by
  # Jordan, run to success minutes later. Its decision + terminal audit rows
  # are stamped newer than every other terminal event (4-5m vs 8m+), so the
  # audit timeline keeps the whole loop at its top no matter how long after
  # seeding a capture runs. The /security screencast frames this request, its
  # run, and its trail.
  approved_at = mins_ago.(12)
  approved_decided_at = mins_ago.(5)
  approved_finished_at = mins_ago.(4)
  approved_decision_reason = "validated config, active connections drained, deploy window open"

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
      policy_reason: "The account policy requires approval for high-risk actions by default."
    })
    |> backdate.(approved_at)

  {:ok, %ApprovalRequest{} = approved_req} =
    Approvals.create_request(approved_run, user.id, "reload after config validation")

  approved_req = backdate_request.(approved_req, approved_at)
  backdate_dispatch_audit.(approved_run, approved_at)

  # Manually mark approved (don't actually dispatch) + backdate the
  # decision so it doesn't pollute "pending" lists.
  approved_req =
    approved_req
    |> Ecto.Changeset.change(
      status: :approved,
      decided_by_id: jordan.id,
      decided_at: approved_decided_at,
      decision_reason: approved_decision_reason
    )
    |> Repo.update!()

  Audit.Events.approval_approved(jordan_subject, approved_req, approved_decision_reason, nil, nil)
  |> Ecto.Changeset.change(occurred_at: approved_decided_at)
  |> Repo.insert!()

  append_chunks.(approved_run, caddy_reload_stdout)

  approved_run =
    approved_run
    |> Ecto.Changeset.change(
      status: :success,
      sent_at: DateTime.add(approved_finished_at, -2, :second),
      started_at: DateTime.add(approved_finished_at, -2, :second),
      finished_at: approved_finished_at,
      exit_code: 0,
      duration_ms: 1820,
      emitted_stdout_bytes: chunks_bytes.(caddy_reload_stdout, "stdout"),
      emitted_stderr_bytes: chunks_bytes.(caddy_reload_stdout, "stderr"),
      emitted_stdout_sha256: chunks_sha.(caddy_reload_stdout, "stdout"),
      emitted_stderr_sha256: chunks_sha.(caddy_reload_stdout, "stderr"),
      output_complete: true
    )
    |> Repo.update!()

  approved_run
  |> Audit.run_event_changeset()
  |> Ecto.Changeset.change(occurred_at: approved_finished_at)
  |> Repo.insert!()

  # A denied one too.
  denied_at = days_ago.(3)
  denied_decision_reason = "Wait for the DBA-approved change window."

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
      policy_reason: "The account policy requires approval for high-risk actions by default."
    })
    |> backdate.(denied_at)

  {:ok, denied_req} =
    Approvals.create_request(
      denied_run,
      user.id,
      "Agent proposed a Postgres reload before the change ticket was approved."
    )

  denied_req = backdate_request.(denied_req, denied_at)
  backdate_dispatch_audit.(denied_run, denied_at)

  denied_req =
    denied_req
    |> Ecto.Changeset.change(
      status: :denied,
      decided_by_id: jordan.id,
      decided_at: denied_at,
      decision_reason: denied_decision_reason
    )
    |> Repo.update!()

  Audit.Events.approval_denied(jordan_subject, denied_req, denied_decision_reason)
  |> Ecto.Changeset.change(occurred_at: denied_at)
  |> Repo.insert!()

  denied_run =
    denied_run
    |> Ecto.Changeset.change(
      status: :cancelled,
      finished_at: denied_at,
      cancelled_at: denied_at,
      reason_text: "approval denied: " <> denied_decision_reason
    )
    |> Repo.update!()

  denied_run
  |> Audit.run_event_changeset()
  |> Ecto.Changeset.change(occurred_at: denied_at)
  |> Repo.insert!()

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

  for {pack_id, action, runner_id, scope, duration} <- [
        {"caddy", "caddy.access_log_tail", edge.id, :any_args, :thirty_days},
        {"postgres", "postgres.replication_lag", database.id, :any_args, :thirty_days}
      ] do
    %{"version" => version, "hash" => hash} =
      pack_descriptor.(pack_id, pack_version_overrides[pack_id])

    fake_run = %Runs.ActionRun{
      account_id: account.id,
      api_key_id: agent_key.id,
      runner_id: runner_id,
      action_id: action,
      pack_ref: "#{pack_id}@#{version}/#{hash}",
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

# The completed runbook execution carries real-shaped physical attempts and
# bounded output, so its detail page demonstrates the same action-output review
# operators get from a live execution. This stays outside the general run seed
# guard: rerunning seeds replaces the runbook executions above, then recreates
# exactly one attempt per completed item here.
succeeded_execution =
  RunbookExecution.Query.by_id(seeded_execution_ids.succeeded)
  |> Repo.one!()

ExecutionItem.Query.by_execution_id(seeded_execution_ids.succeeded)
|> Repo.all()
|> Enum.each(fn item ->
  seed_terminal_history.(fn ->
    args = if is_binary(item.args_raw), do: Jason.decode!(item.args_raw), else: %{}

    {:ok, attempt} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: item.runner_id,
        action_id: item.action_id,
        args: args,
        reason: succeeded_execution.reason,
        source: "operator",
        requested_by_id: user.id,
        initiating_membership_id: owner_membership.id,
        pack_ref: item.pack_ref,
        runner_ref: item.runner_ref,
        runbook_id: approval_runbook.id,
        runbook_step_id: item.step_id,
        runbook_execution_id: seeded_execution_ids.succeeded,
        runbook_execution_item_id: item.id,
        attempt_number: 1,
        expected_pack_hash: item.pack_hash,
        policy_id: item.policy_id,
        policy_version: item.policy_version,
        policy_decision: "allow",
        policy_reason:
          item.policy_reason <> " The approved runbook plan authorized this execution.",
        status: "running"
      })

    chunks =
      case item.action_id do
        "caddy.reload_config" ->
          runner_name = item.runner_ref |> String.split("~") |> hd()

          [
            {"stdout", "Valid configuration\n"},
            {"stdout", "Reloaded Caddy configuration on #{runner_name}\n"}
          ]

        "caddy.version" ->
          [{"stdout", "v2.8.4 h1:0n6wXAMXxVqI9eD/9KspXHiCmGX95e9FQeawhe2iZHQ=\n"}]

        "caddy.reverse_proxy_upstreams" ->
          [{"stdout", "{\"healthy\":true,\"upstreams\":2}\n"}]

        _other ->
          [{"stdout", "Action completed successfully\n"}]
      end

    Enum.with_index(chunks, 1)
    |> Enum.each(fn {{stream, chunk}, seq} ->
      {:ok, _event} =
        Runs.append_event(attempt, %{
          seq: seq,
          kind: "progress",
          stream: stream,
          payload: %{"chunk" => chunk}
        })
    end)

    executed_command =
      case item.action_id do
        "caddy.reload_config" ->
          "caddy reload --config /etc/caddy/Caddyfile"

        "caddy.version" ->
          "caddy version"

        "caddy.reverse_proxy_upstreams" ->
          ~s(/bin/sh -c 'curl -fsS "${CADDY_ADMIN:-http://127.0.0.1:2019}/reverse_proxy/upstreams"')

        _other ->
          nil
      end

    attempt
    |> ActionRun.Changeset.transition(:success, %{
      started_at: DateTime.add(succeeded_at, 6, :second),
      finished_at: succeeded_finished_at,
      exit_code: 0,
      duration_ms: 12_000,
      output_complete: true,
      executed_command: executed_command,
      event_id: "seed-runbook-" <> item.id
    })
    |> Repo.update!()
  end)
end)

IO.puts(IO.ANSI.cyan() <> "✓ Seeded runbook action output previews" <> IO.ANSI.reset())

# -- Bootstrap enrollment key (unchanged) ----------------------------------

case Runners.list_enrollment_keys(owner_subject) do
  {:ok, [], _} ->
    case System.get_env("EMISAR_DEV_FIXED_ENROLLMENT_KEY") do
      fixed when is_binary(fixed) and byte_size(fixed) >= 29 ->
        {:ok, _key} =
          Emisar.Runners.EnrollmentKey.Changeset.create_with_secret(account.id, user.id, fixed, %{
            description: "Dev fixed enrollment key (docker-compose)",
            group: "dev-docker",
            reusable: true
          })
          |> Repo.insert()

        IO.puts(IO.ANSI.green() <> "✓ Seeded dev fixed enrollment key" <> IO.ANSI.reset())

      _ ->
        {:ok, raw, _key} =
          Runners.create_enrollment_key(
            %{
              description: "Demo enrollment key",
              group: "edge-web",
              reusable: true
            },
            owner_subject
          )

        IO.puts("")
        IO.puts(IO.ANSI.green() <> "Bootstrap a runner:" <> IO.ANSI.reset())

        IO.puts(
          "  curl -sSL https://emisar.dev/install.sh | sudo EMISAR_ENROLLMENT_KEY=#{raw} bash"
        )

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

# -- Pagination volume -------------------------------------------------
#
# Every paginated console list has to span more than one page on this account so
# first/middle/last page and the cursor between them are all testable. The
# paginator's page is 35 rows; the approvals tabs and the profile's session list
# ask for 15. Each list below is filled to roughly two full pages plus a partial
# third.
#
# Filler sits BEHIND the curated rows so page one still reads the way the docs
# captures and the capture rig expect it. For a time-ordered list that means
# stacking backwards from the OLDEST row already present, which keeps page one
# right on a database seeded weeks ago as well as on a fresh one. The two
# name-ordered lists get names that sort after every curated one: runners order
# by group then name, so every filler group sorts after "edge-web"; runbooks
# order by title, so every filler title starts past "Morning edge readiness".
# The approvals queue is FIFO and is filled far above, where a dispatch at seed
# time is newest by construction.
#
# Each block writes ONE insert_all and inserts only the rows that are missing,
# so a reseed converges instead of doubling and never removes a row a developer
# added by hand.

# insert_all skips changesets, so validate first, then supply what it will not
# autogenerate — the id and the timestamps.
insert_seed_rows = fn schema, pairs ->
  rows =
    Enum.map(pairs, fn {changeset, extra} ->
      if changeset.valid? do
        Map.merge(changeset.changes, extra)
      else
        raise "seed volume built an invalid #{inspect(schema)}: #{inspect(changeset.errors)}"
      end
    end)

  {count, _returned} = Repo.insert_all(schema, rows)
  count
end

oldest_at = fn queryable, field -> Repo.aggregate(queryable, :min, field) || now.() end
step_back = fn from, index, seconds -> DateTime.add(from, -(index + 1) * seconds, :second) end
cycle = fn list, index -> Enum.at(list, rem(index, length(list))) end

# -- Fleet volume ------------------------------------------------------

filler_runner_hosts =
  for {group, role} <- [
        {"metrics-prom", "metrics"},
        {"queue-rabbit", "queue"},
        {"search-opensearch", "search"},
        {"shard-mysql", "database"},
        {"vault-secrets", "secrets"},
        {"worker-batch", "worker"}
      ],
      region <- ~w[fra iad sfo bom gru lhr nrt],
      ordinal <- ~w[01 02] do
    %{
      name: "#{group}-#{region}-#{ordinal}",
      group: group,
      hostname: "#{group}-#{region}-#{ordinal}.northstar.example",
      labels: %{"env" => "prod", "region" => region, "role" => role}
    }
  end

# The runner detail page paginates one runner's advertised actions, so the fleet
# needs a host that carries a broad catalog rather than the handful the curated
# runners advertise. A jump host is where an operator would expect to find one.
jumphost_names = ~w[ops-jump-01 ops-jump-02]

filler_runner_hosts =
  filler_runner_hosts ++
    Enum.map(jumphost_names, fn name ->
      %{
        name: name,
        group: "ops-jumphost",
        hostname: "#{name}.northstar.example",
        labels: %{"env" => "prod", "region" => "iad", "role" => "jumphost"}
      }
    end)

seeded_runner_names =
  Runner.Query.not_deleted()
  |> Runner.Query.by_account_id(account.id)
  |> Repo.all()
  |> MapSet.new(& &1.name)

oldest_runner_at =
  oldest_at.(
    Runner.Query.not_deleted() |> Runner.Query.by_account_id(account.id),
    :inserted_at
  )

runners_added =
  filler_runner_hosts
  |> Enum.reject(&MapSet.member?(seeded_runner_names, &1.name))
  |> Enum.with_index()
  |> Enum.map(fn {host, index} ->
    at = step_back.(oldest_runner_at, index, 3600)

    # Read from Compat rather than pinning a literal: the curated four carry the
    # deliberately-behind versions that earn the fleet's "needs an update"
    # notice, and filler on a stale literal would drown that story in 86 more
    # rows the moment the target moves.
    changeset =
      host
      |> Map.merge(%{
        account_id: account.id,
        external_id: host.name,
        runner_version: Emisar.Compat.runner_target()
      })
      |> Runner.Changeset.register()

    {changeset, %{id: Repo.generate_id(), inserted_at: at, updated_at: at, last_connected_at: at}}
  end)
  |> then(&insert_seed_rows.(Runner, &1))

filler_runner_names = MapSet.new(filler_runner_hosts, & &1.name)

jumphost_actions =
  Enum.flat_map(~w[linux-core docker nginx debian], baseline_action_descriptors)

Runner.Query.not_deleted()
|> Runner.Query.by_account_id(account.id)
|> Repo.all()
|> Enum.filter(&MapSet.member?(filler_runner_names, &1.name))
|> Enum.each(fn runner ->
  if runner.name == "ops-jump-01" do
    advertise.(runner, jumphost_actions)
  else
    advertise.(runner, linux_actions)
  end
end)

IO.puts(
  IO.ANSI.cyan() <>
    "✓ Fleet volume: +#{runners_added} runners (ops-jump-01 advertises #{length(jumphost_actions)} actions)" <>
    IO.ANSI.reset()
)

# -- Runbook volume ----------------------------------------------------
#
# Published on insert (definition + live_version, no draft) so every filler row
# is runnable rather than wearing the "Never published" state, which would make
# the list read as a page of broken runbooks.

filler_runbook_definition = %{
  "schema_version" => 1,
  "context_markdown" =>
    "## Before you run\n\n- Confirm the change window is open.\n" <>
      "- Watch the fleet for a full minute after the step reports success.",
  "inputs" => [],
  "stages" => [
    %{
      "id" => "check",
      "title" => "Check the fleet",
      "mode" => "parallel",
      "max_parallel" => 2,
      "steps" => [
        %{
          "id" => "uptime",
          "pack" => %{"id" => "linux-core"},
          "action" => "linux.uptime",
          "targets" => %{"selection" => "all", "refs" => ["group:edge-web"]},
          "args" => %{},
          "outputs" => [],
          "success" => [],
          "wait" => nil
        }
      ]
    }
  ]
}

filler_runbook_digest = Runbooks.definition_digest(filler_runbook_definition)

filler_runbook_titles =
  for verb <- [
        "Prune",
        "Publish",
        "Purge",
        "Quarantine",
        "Rebalance",
        "Refresh",
        "Reindex",
        "Reload",
        "Renew",
        "Replay",
        "Restart",
        "Restore",
        "Retire",
        "Roll back",
        "Scale",
        "Snapshot",
        "Stage",
        "Sweep",
        "Sync",
        "Trim",
        "Upgrade",
        "Validate"
      ],
      target <- [
        "the edge fleet",
        "the checkout tier",
        "the search cluster",
        "the metrics pipeline"
      ],
      do: "#{verb} #{target}"

seeded_runbook_slugs =
  Runbook.Query.not_deleted()
  |> Runbook.Query.by_account_id(account.id)
  |> Repo.all()
  |> MapSet.new(& &1.slug)

oldest_runbook_at =
  oldest_at.(
    Runbook.Query.not_deleted() |> Runbook.Query.by_account_id(account.id),
    :inserted_at
  )

filler_runbook_pairs =
  filler_runbook_titles
  |> Enum.map(fn title ->
    Runbook.Changeset.create(account.id, user.id, %{
      title: title,
      description:
        "#{title} on the standard change checklist, then confirm the fleet reports healthy.",
      draft_definition: filler_runbook_definition
    })
  end)
  |> Enum.reject(&MapSet.member?(seeded_runbook_slugs, Ecto.Changeset.get_field(&1, :slug)))
  |> Enum.with_index()
  |> Enum.map(fn {changeset, index} ->
    at = step_back.(oldest_runbook_at, index, 3600)

    {changeset,
     %{
       id: Repo.generate_id(),
       inserted_at: at,
       updated_at: at,
       definition: filler_runbook_definition,
       draft_definition: nil,
       live_version: 1
     }}
  end)

runbooks_added = insert_seed_rows.(Runbook, filler_runbook_pairs)

filler_runbook_pairs
|> Enum.map(fn {changeset, extra} ->
  release =
    Release.Changeset.create(%{
      account_id: account.id,
      runbook_id: extra.id,
      version: 1,
      title: Ecto.Changeset.get_field(changeset, :title),
      description: Ecto.Changeset.get_field(changeset, :description),
      definition: filler_runbook_definition,
      definition_sha256: filler_runbook_digest,
      published_by_id: user.id
    })

  {release,
   %{id: Repo.generate_id(), inserted_at: extra.inserted_at, updated_at: extra.updated_at}}
end)
|> then(&insert_seed_rows.(Release, &1))

IO.puts(
  IO.ANSI.cyan() <> "✓ Runbook volume: +#{runbooks_added} published runbooks" <> IO.ANSI.reset()
)

# -- Roster volume -----------------------------------------------------

filler_people =
  for first <- ~w[amara bevan chidi dagny elif farrah gustavo hina imani],
      last <- ~w[abara becker castellanos duarte eriksen fontaine grimaldi haugen ibarra] do
    {"#{first}.#{last}@northstar.example",
     "#{String.capitalize(first)} #{String.capitalize(last)}"}
  end

oldest_membership_at =
  oldest_at.(
    Accounts.Membership.Query.not_deleted()
    |> Accounts.Membership.Query.by_account_id(account.id),
    :inserted_at
  )

known_filler_user_ids =
  Enum.reduce(filler_people, %{}, fn {email, _name}, acc ->
    case Users.fetch_user_by_email(email) do
      {:ok, %User{} = existing} -> Map.put(acc, email, existing.id)
      {:error, :not_found} -> acc
    end
  end)

minted_filler_user_ids =
  filler_people
  |> Enum.reject(fn {email, _name} -> Map.has_key?(known_filler_user_ids, email) end)
  |> Enum.with_index()
  |> Enum.map(fn {{email, full_name}, index} ->
    at = step_back.(oldest_membership_at, index, 3600)
    changeset = User.Changeset.registration(%User{}, %{email: email, full_name: full_name})

    {email, changeset,
     %{id: Repo.generate_id(), inserted_at: at, updated_at: at, confirmed_at: at}}
  end)

minted_filler_user_ids
|> Enum.map(fn {_email, changeset, extra} -> {changeset, extra} end)
|> then(&insert_seed_rows.(User, &1))

filler_user_ids =
  Enum.reduce(minted_filler_user_ids, known_filler_user_ids, fn {email, _changeset, extra}, acc ->
    Map.put(acc, email, extra.id)
  end)

seeded_membership_user_ids =
  Accounts.Membership.Query.not_deleted()
  |> Accounts.Membership.Query.by_account_id(account.id)
  |> Repo.all()
  |> MapSet.new(& &1.user_id)

memberships_added =
  filler_people
  |> Enum.map(fn {email, _name} -> Map.fetch!(filler_user_ids, email) end)
  |> Enum.reject(&MapSet.member?(seeded_membership_user_ids, &1))
  |> Enum.with_index()
  |> Enum.map(fn {user_id, index} ->
    at = step_back.(oldest_membership_at, index, 3600)

    changeset =
      Accounts.Membership.Changeset.create(%{
        account_id: account.id,
        user_id: user_id,
        role: cycle.([:viewer, :operator, :operator, :viewer, :admin], index),
        runner_access_mode: :all,
        pack_access_mode: :all,
        invitation_accepted_at: at
      })

    {changeset, %{id: Repo.generate_id(), inserted_at: at, updated_at: at}}
  end)
  |> then(&insert_seed_rows.(Accounts.Membership, &1))

IO.puts(IO.ANSI.cyan() <> "✓ Roster volume: +#{memberships_added} members" <> IO.ANSI.reset())

# -- Credential volume -------------------------------------------------
#
# Both key kinds are minted the way the product mints them — Crypto owns the
# secret, its lookup prefix, and the stored digest — so no seeded row carries a
# digest this file wrote by hand.

priya_membership = Accounts.peek_sync_membership(account.id, priya.id)
sam_membership = Accounts.peek_sync_membership(account.id, sam.id)

filler_key_owners = [
  {user, owner_membership.id},
  {jordan, jordan_membership.id},
  {priya, priya_membership.id},
  {sam, sam_membership.id}
]

# `client_info` is what the named client really reports at `initialize`, so the
# row's client segment agrees with its name. Pairing a name with whatever client
# the owner rotation happened to land on printed "Claude Code - search / client
# cursor" — the list reads that disagreement as credential drift, which is a
# real state worth one row, not eighty-four.
filler_key_specs =
  for {client, client_info} <- [
        {"Claude Code", %{"name" => "claude-code", "title" => "Claude Code"}},
        {"Codex CLI", %{"name" => "Codex"}},
        {"Cursor", %{"name" => "cursor"}},
        {"Gemini CLI", %{"name" => "gemini-cli-mcp-client"}},
        {"Windsurf", %{"name" => "windsurf"}},
        {"Zed", %{"name" => "zed"}}
      ],
      squad <- ~w[payments checkout search catalog platform growth data
                  mobile infra identity billing notifications media support],
      do: {"#{client} - #{squad}", client_info}

seeded_key_names =
  ApiKeys.ApiKey.Query.not_deleted()
  |> ApiKeys.ApiKey.Query.by_account_id(account.id)
  |> Repo.all()
  |> MapSet.new(& &1.name)

oldest_key_at =
  oldest_at.(
    ApiKeys.ApiKey.Query.not_deleted() |> ApiKeys.ApiKey.Query.by_account_id(account.id),
    :inserted_at
  )

keys_added =
  filler_key_specs
  |> Enum.reject(fn {name, _client_info} -> MapSet.member?(seeded_key_names, name) end)
  |> Enum.with_index()
  |> Enum.map(fn {{name, client_info}, index} ->
    at = step_back.(oldest_key_at, index, 3600)
    {owner, membership_id} = cycle.(filler_key_owners, index)
    {_raw, prefix, hash} = Emisar.Crypto.mint("emk-", 12)

    changeset =
      ApiKeys.ApiKey.Changeset.create(account.id, owner.id, membership_id, prefix, hash, %{
        name: name
      })

    {changeset,
     %{
       id: Repo.generate_id(),
       inserted_at: at,
       updated_at: at,
       last_used_at: DateTime.add(at, 3600, :second),
       # Current bridge, read from Compat: the curated fleet owns the stale-bridge
       # story (one unsupported, the rest a release behind), and filler pinned to
       # the same literal turned that quiet nudge into "33 agents are behind".
       last_client_info: Map.put(client_info, "bridge_version", Emisar.Compat.mcp_target())
     }}
  end)
  |> then(&insert_seed_rows.(ApiKeys.ApiKey, &1))

filler_enrollment_descriptions =
  for role <- ~w[metrics queue search database secrets worker jumphost],
      region <- ~w[fra iad sfo bom gru lhr],
      wave <- ~w[rollout rebuild],
      do: "#{role} fleet #{region} - #{wave}"

seeded_enrollment_descriptions =
  Emisar.Runners.EnrollmentKey.Query.not_deleted()
  |> Emisar.Runners.EnrollmentKey.Query.by_account_id(account.id)
  |> Repo.all()
  |> MapSet.new(& &1.description)

oldest_enrollment_at =
  oldest_at.(
    Emisar.Runners.EnrollmentKey.Query.not_deleted()
    |> Emisar.Runners.EnrollmentKey.Query.by_account_id(account.id),
    :inserted_at
  )

enrollment_keys_added =
  filler_enrollment_descriptions
  |> Enum.reject(&MapSet.member?(seeded_enrollment_descriptions, &1))
  |> Enum.with_index()
  |> Enum.map(fn {description, index} ->
    at = step_back.(oldest_enrollment_at, index, 3600)
    {_raw, prefix, hash} = Emisar.Crypto.mint("emkey-enroll-", 29)

    changeset =
      Emisar.Runners.EnrollmentKey.Changeset.create(account.id, user.id, prefix, hash, %{
        description: description,
        reusable: true,
        max_uses: 25
      })

    {changeset,
     %{
       id: Repo.generate_id(),
       inserted_at: at,
       updated_at: at,
       uses_count: rem(index, 7),
       last_used_at: DateTime.add(at, 7200, :second)
     }}
  end)
  |> then(&insert_seed_rows.(Emisar.Runners.EnrollmentKey, &1))

IO.puts(
  IO.ANSI.cyan() <>
    "✓ Credential volume: +#{keys_added} agent keys, +#{enrollment_keys_added} enrollment keys" <>
    IO.ANSI.reset()
)

# -- Session volume ----------------------------------------------------
#
# The profile's session list is the demo owner's own, so the filler is theirs —
# older than whatever the developer is signed in with, which keeps the live
# session at the top where "this device" belongs.

# Real user-agent strings, because the row label is PARSED from one: a friendly
# "Chrome on Windows" written straight into the column comes back out of the
# parser as a bare "Chrome".
filler_session_devices = [
  {"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) " <>
     "Chrome/140.0.0.0 Safari/537.36", "203.0.113.24"},
  {"Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) " <>
     "Version/18.0 Mobile/15E148 Safari/604.1", "203.0.113.61"},
  {"Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0", "198.51.100.32"},
  {"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) " <>
     "Chrome/140.0.0.0 Safari/537.36", "198.51.100.88"},
  {"Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 " <>
     "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", "203.0.113.147"}
]

demo_session_query =
  Emisar.Auth.UserToken.Query.by_user_id(user.id)
  |> Emisar.Auth.UserToken.Query.by_context("session")

oldest_session_at = oldest_at.(demo_session_query, :inserted_at)
session_shortfall = max(40 - Repo.aggregate(demo_session_query, :count, :id), 0)

sessions_added =
  0..(session_shortfall - 1)//1
  |> Enum.map(fn index ->
    at = step_back.(oldest_session_at, index, 43_200)
    {device, ip} = cycle.(filler_session_devices, index)
    {_token, digest} = Emisar.Crypto.session_token()

    metadata = %{ip_address: ip, user_agent: device}
    changeset = Emisar.Auth.UserToken.Changeset.session(user, digest, metadata, :magic_link, nil)

    {changeset, %{id: Repo.generate_id(), inserted_at: at}}
  end)
  |> then(&insert_seed_rows.(Emisar.Auth.UserToken, &1))

# -- Run + decision volume ---------------------------------------------
#
# Every filler run is older than the oldest curated one, so the runs list, the
# dashboard's recent-runs rail and its 24h digest all keep reading exactly as
# they do today; only pages two and beyond are new.

filler_run_shapes = [
  {edge, "linux.uptime", %{}, "scheduled edge readiness sweep"},
  {edge, "caddy.reverse_proxy_upstreams", %{}, "confirm upstreams after the weekly deploy"},
  {edge, "linux.disk_usage", %{"paths" => ["/", "/var/log"]}, "capacity check before the peak"},
  {edge, "caddy.version", %{}, "record the running Caddy build for the change ticket"},
  {api, "systemd.failed_units", %{}, "handoff health sweep"},
  {api, "linux.journalctl", %{"unit" => "checkout-api.service", "since" => "1h"},
   "review checkout-api warnings after the release"},
  {api, "linux.uptime", %{}, "confirm the API tier stayed up through the window"},
  {database, "postgres.replication_lag", %{}, "confirm replicas caught up after the import"},
  {database, "postgres.vacuum_status", %{"schema" => "public", "limit" => 20},
   "autovacuum check before the batch window"},
  {database, "linux.disk_usage", %{"paths" => ["/var/lib/postgresql"]},
   "watch WAL growth during the backfill"}
]

filler_run_requesters = [
  {user.id, owner_membership.id},
  {jordan.id, jordan_membership.id},
  {priya.id, priya_membership.id}
]

run_query = ActionRun.Query.all() |> ActionRun.Query.by_account_id(account.id)
oldest_run_at = oldest_at.(run_query, :inserted_at)
run_shortfall = max(90 - Repo.aggregate(run_query, :count, :id), 0)

filler_run_rows =
  0..(run_shortfall - 1)//1
  |> Enum.map(fn index ->
    at = step_back.(oldest_run_at, index, 10_800)
    {runner, action_id, args, reason} = cycle.(filler_run_shapes, index)
    args_raw = Jason.encode!(args)
    duration_ms = 240 + rem(index * 137, 1800)

    # Every twelfth run failed and every twentieth was called off — enough for
    # the status filter to have something to find without putting a fresh
    # warning on a dashboard that should read healthy.
    {status, exit_code} =
      cond do
        rem(index, 20) == 19 -> {"cancelled", nil}
        rem(index, 12) == 11 -> {"failed", 1}
        true -> {"success", 0}
      end

    # `Runs.create_run/1` derives the initiating membership from the requester
    # and the runs list reads attribution through it — without one, a row falls
    # back to the raw email while every curated row beside it reads as a name.
    {requester_id, requester_membership_id} = cycle.(filler_run_requesters, index)

    changeset =
      ActionRun.Changeset.create(%{
        account_id: account.id,
        runner_id: runner.id,
        request_id: Emisar.Crypto.run_request_id(),
        action_id: action_id,
        args: args,
        args_sha256: Emisar.Crypto.hash_hex(args_raw),
        source: "operator",
        requested_by_id: requester_id,
        initiating_membership_id: requester_membership_id,
        reason: reason,
        status: status,
        policy_id: policy && policy.id,
        policy_decision: "allow",
        policy_reason: "The account policy allows low-risk actions by default.",
        queued_at: at
      })

    finished_at = DateTime.add(at, duration_ms, :millisecond)

    {changeset,
     %{
       id: Repo.generate_id(),
       inserted_at: at,
       updated_at: finished_at,
       sent_at: at,
       started_at: at,
       finished_at: finished_at,
       cancelled_at: if(status == "cancelled", do: finished_at),
       exit_code: exit_code,
       duration_ms: duration_ms,
       output_complete: status != "cancelled",
       error_message: if(status == "failed", do: "the action exited non-zero; see the output")
     }}
  end)

runs_added = insert_seed_rows.(ActionRun, filler_run_rows)

# The approvals "Recent decisions" tab reads the same table as the queue but
# newest-first, so its filler is the OLD end: one decided request against the
# oldest runs that do not have one yet. Read back from the table rather than
# from the batch just inserted, so the tab refills on its own when the runs are
# already at volume.
decision_query = ApprovalRequest.Query.all() |> ApprovalRequest.Query.by_account_id(account.id)
oldest_decision_at = oldest_at.(decision_query, :requested_at)

decided_shortfall =
  max(40 - Repo.aggregate(ApprovalRequest.Query.decided(decision_query), :count, :id), 0)

runs_already_requested =
  decision_query
  |> Repo.all()
  |> MapSet.new(& &1.run_id)

decisions_added =
  run_query
  |> Repo.all()
  |> Enum.reject(&MapSet.member?(runs_already_requested, &1.id))
  |> Enum.sort_by(& &1.inserted_at, DateTime)
  |> Enum.take(decided_shortfall)
  |> Enum.with_index()
  |> Enum.map(fn {%ActionRun{} = run, index} ->
    requested_at = step_back.(oldest_decision_at, index, 10_800)
    approved? = rem(index, 3) != 2

    changeset =
      ApprovalRequest.Changeset.create(%{
        account_id: account.id,
        run_id: run.id,
        requested_by_id: cycle.([priya.id, sam.id, jordan.id], index),
        requested_at: requested_at,
        min_approvals: 1,
        allow_self_approval: true,
        reason: "Change ticket is open and the smoke test is green.",
        expires_at: DateTime.add(requested_at, 24 * 3600, :second),
        # The decisions list names the action and its host from this snapshot,
        # not from the run — a request written without it renders as "— on —".
        context: %{
          runner_id: run.runner_id,
          action_id: run.action_id,
          args_sha256: run.args_sha256
        }
      })

    {changeset,
     %{
       id: Repo.generate_id(),
       inserted_at: requested_at,
       updated_at: requested_at,
       status: if(approved?, do: :approved, else: :denied),
       decided_by_id: if(approved?, do: jordan.id, else: user.id),
       decided_at: DateTime.add(requested_at, 240, :second),
       decision_reason:
         if(approved?,
           do: "Window is open and the plan matches the ticket.",
           else: "Wait for the DBA-approved change window."
         )
     }}
  end)
  |> then(&insert_seed_rows.(ApprovalRequest, &1))

# Standing grants: the same "ask once, then run" shape as the two curated ones,
# spread across the actions the agent fleet actually calls.
filler_grant_shapes =
  for {pack_id, action_id, runner} <- [
        {"caddy", "caddy.access_log_tail", edge},
        {"caddy", "caddy.reverse_proxy_upstreams", edge},
        {"caddy", "caddy.version", edge},
        {"linux-core", "linux.uptime", edge},
        {"linux-core", "linux.disk_usage", api},
        {"systemd-deep", "systemd.failed_units", api},
        {"linux-core", "linux.journalctl", api},
        {"postgres", "postgres.replication_lag", database},
        {"postgres", "postgres.vacuum_status", database},
        {"linux-core", "linux.uptime", database}
      ],
      args <- [%{}, %{"lines" => 100}, %{"lines" => 500}, %{"lines" => 1000}],
      do: {pack_id, action_id, runner, args}

grant_query =
  Emisar.Approvals.Grant.Query.all() |> Emisar.Approvals.Grant.Query.by_account_id(account.id)

oldest_grant_at = oldest_at.(grant_query, :granted_at)
grant_shortfall = max(40 - Repo.aggregate(grant_query, :count, :id), 0)

grants_added =
  filler_grant_shapes
  |> Enum.take(grant_shortfall)
  |> Enum.with_index()
  |> Enum.map(fn {{pack_id, action_id, runner, args}, index} ->
    granted_at = step_back.(oldest_grant_at, index, 21_600)

    %{"version" => version, "hash" => hash} =
      pack_descriptor.(pack_id, pack_version_overrides[pack_id])

    changeset =
      Emisar.Approvals.Grant.Changeset.create(%{
        account_id: account.id,
        api_key_id: agent_key.id,
        action_id: action_id,
        pack_ref: "#{pack_id}@#{version}/#{hash}",
        runner_id: runner.id,
        args_sha256: Emisar.Crypto.hash_hex(Jason.encode!(args)),
        granted_by_id: cycle.([user.id, jordan.id], index),
        granted_at: granted_at,
        expires_at: DateTime.add(granted_at, 30 * 86_400, :second),
        uses_count: rem(index * 3, 17)
      })

    {changeset, %{id: Repo.generate_id(), inserted_at: granted_at, updated_at: granted_at}}
  end)
  |> then(&insert_seed_rows.(Emisar.Approvals.Grant, &1))

IO.puts(
  IO.ANSI.cyan() <>
    "✓ Activity volume: +#{runs_added} runs, +#{decisions_added} decided approvals, " <>
    "+#{grants_added} grants, +#{sessions_added} sessions" <>
    IO.ANSI.reset()
)

# The audit trail needs no filler of its own: a fresh seed writes 104 events for
# this account — three pages — because every seeded mutation above already logs
# one through its own domain call. Synthetic audit rows would only add rows the
# rest of the account cannot explain.

# -- Keycloak OIDC + SCIM provider (./run e2e SSO) -----------------
# Seeds an enabled :keycloak IdentityProvider on the demo (enterprise) account
# pointing at the local Keycloak, plus a fixed dev SCIM bearer — so the shared
# dev stack exercises OIDC login AND inbound SCIM provisioning end to end.
# Gated on the same fixed-dev-value env vars as the auth/MCP keys; a no-op when
# unset, so a prod-style seed never creates an IdP. Idempotent (skips if the
# account already has a provider and reconciles SCIM on the known dev provider).
keycloak_secret = System.get_env("EMISAR_DEV_FIXED_OIDC_CLIENT_SECRET")

provider_id =
  System.get_env("EMISAR_DEV_KEYCLOAK_PROVIDER_ID") || "11111111-1111-7111-8111-111111111111"

keycloak_present? =
  Emisar.SSO.IdentityProvider.Query.not_deleted()
  |> Emisar.SSO.IdentityProvider.Query.by_account_id(account.id)
  |> Repo.exists?()

if not keycloak_present? and is_binary(keycloak_secret) and keycloak_secret != "" do
  issuer = System.get_env("EMISAR_DEV_KEYCLOAK_ISSUER") || "https://keycloak:8443/realms/emisar"

  # Build the row directly (Changeset.change, not create): the dev Keycloak runs
  # as the portal's localhost sidecar, so its issuer is a loopback URL — which
  # `IssuerUrl` (the SSRF guard in Changeset.create) correctly rejects for
  # OPERATOR-supplied issuers. The seed is trusted infra pointing at a known dev
  # provider, not attacker input, so it bypasses that guard; the console config
  # path stays fully guarded.
  {:ok, _provider} =
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
end

case System.get_env("EMISAR_DEV_FIXED_SCIM_TOKEN") do
  raw when is_binary(raw) and byte_size(raw) > 12 ->
    provider =
      Emisar.SSO.IdentityProvider.Query.not_deleted()
      |> Emisar.SSO.IdentityProvider.Query.by_account_id(account.id)
      |> Emisar.SSO.IdentityProvider.Query.by_id(provider_id)
      |> Repo.peek()

    if provider do
      {:ok, _} =
        provider
        |> Emisar.SSO.IdentityProvider.Changeset.scim_token(
          String.slice(raw, 0, 12),
          Emisar.Crypto.hash(raw),
          true
        )
        |> Repo.update()
    end

  _ ->
    :ok
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
  # Deterministic on purpose. This block used to look for a SCIM-ENABLED provider
  # and silently do nothing when it found none, so whether the seeded database
  # had directory members depended on invisible state — and the docs captures for
  # the team and SSO pages came out empty with a seed that reported success.
  #
  # `./run seed` always sets this token alongside the OIDC secret, so reaching
  # here with no provider at all means something upstream genuinely failed. Say
  # so. A provider that exists but has SCIM off is repaired instead, which is
  # what makes a re-seed over an older database converge.
  providers =
    case Emisar.SSO.list_providers_for_account(owner_subject) do
      {:ok, found, _meta} -> found
      _ -> []
    end

  scim_provider =
    case Enum.find(providers, & &1.scim_enabled) do
      %Emisar.SSO.IdentityProvider{} = enabled ->
        enabled

      nil ->
        case providers do
          [provider | _] ->
            {:ok, enabled, _raw_token} = Emisar.SSO.enable_scim(provider, owner_subject)
            enabled

          [] ->
            raise """
            EMISAR_DEV_FIXED_SCIM_TOKEN is set, so this seed is meant to create             directory-sync state, but the demo account has no identity provider             to attach it to. The team and SSO docs captures need those members.             Check that Keycloak came up and that EMISAR_DEV_FIXED_OIDC_CLIENT_SECRET             reached the seed.\
            """
        end
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

    # Certifying against a live IdP points a real directory at this connection,
    # which leaves behind identities the seed never created (an operator's own
    # Okta sign-in, an IdP's activation probe) and SCIM can only deactivate,
    # never remove — so they linger in the "Synced users" card and would ship in
    # its docs capture. Converge on the four synthetic people above: drop the
    # stray identity and the account membership it provisioned.
    seeded_external_ids = Enum.map(scim_people, fn {ext, _email, _name} -> ext end)

    stray_identities =
      Emisar.SSO.UserIdentity.Query.not_deleted()
      |> Emisar.SSO.UserIdentity.Query.by_provider_id(scim_provider.id)
      |> Repo.all()
      |> Enum.reject(&(&1.provider_identifier in seeded_external_ids))

    for identity <- stray_identities do
      {:ok, _} =
        identity
        |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
        |> Repo.update()

      membership_query =
        Accounts.Membership.Query.not_deleted()
        |> Accounts.Membership.Query.by_account_and_user(
          identity.account_id,
          identity.user_id
        )

      for membership <- Repo.all(membership_query) do
        {:ok, _} =
          membership
          |> Accounts.Membership.Changeset.delete()
          |> Repo.update()
      end
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

  # Reconcile the Paddle link to the persona so a reseed can't leave an account
  # wearing a prior run's customer id — a stale id lights up "Manage subscription"
  # and the stub PaddleClient's fake invoices on a page that should show none (the
  # Blank Workspace free account did exactly this). Only the team persona is
  # self-serve in dev; every other tier is nil.
  paddle_customer_id = if plan == "team", do: "ctm_dev_#{slug}", else: nil

  acct =
    acct
    |> Ecto.Changeset.change(paddle_customer_id: paddle_customer_id)
    |> Repo.update!()

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

# A "both connected, no actions" account — one runner AND one agent, but the
# runner advertises an empty catalog — so the onboarding checklist must explain
# how to install a catalog pack before offering a run prompt. Demo-owned, reachable by
# switching accounts as demo. Existence-checked, so it repairs the account demo
# already made by hand rather than duplicating its runner.
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

bc_runner =
  case Runners.list_all_runners_for_account(bc_subject) do
    {:ok, [runner | _]} ->
      runner

    _ ->
      {:ok, runner} =
        insert_seed_runner.(both_connected_account.id, %{
          name: "both-connected-prod-1",
          group: "prod"
        })

      runner
      |> Ecto.Changeset.change(
        hostname: "both-connected-prod-1.example",
        last_connected_at: mins_ago.(20),
        runner_version: "0.4.2"
      )
      |> Repo.update!()
  end

advertise.(bc_runner, [])

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
    "✓ Both Connected Co (slug=both-connected) — runner + agent, no actions" <>
    IO.ANSI.reset()
)

# -- Emisar staff account ---------------------------------------------
# The platform-admin persona for `/admin`, owning its OWN workspace rather than
# taking a seat in Northstar Labs: the demo accounts feed the docs screenshot
# captures, so their member lists must not grow a staff row. The workspace stays
# empty on purpose — it doubles as the empty-states surface.
#
# This is the ONE persona deliberately kept out of `clear_seeded_mfa`. `/admin`
# demands a second factor proved against the CURRENT enrollment, so a developer
# enrolls TOTP here once by hand, and a reseed must leave that enrollment — and
# the `is_admin` flag — standing rather than disabling it the way the screenshot
# personas need. The seed still never enrolls MFA nor mints a secret; that stays
# the human's step, walked by the gate itself.
staff_email = "admin@emisar.dev"
staff_full_name = "Emisar Admin"

staff_user =
  case Users.fetch_user_by_email(staff_email) do
    {:error, :not_found} ->
      {:ok, registered} = Users.register_user(%{full_name: staff_full_name, email: staff_email})
      confirm_user.(registered)

    {:ok, %User{} = existing} ->
      existing |> ensure_profile.(staff_full_name) |> confirm_user.()
  end

staff_user =
  if staff_user.is_admin do
    staff_user
  else
    # `is_admin` is a global platform flag no changeset casts and no context
    # writes — it is set out of band by design, so the seed builds the row itself.
    staff_user |> Ecto.Changeset.change(is_admin: true) |> Repo.update!()
  end

staff_account_query = Account.Query.not_deleted() |> Account.Query.by_slug("emisar-staff")

_ =
  case Repo.fetch(staff_account_query, Account.Query) do
    {:error, :not_found} ->
      {:ok, created} =
        Accounts.create_account_with_owner(
          %{name: "Emisar Staff", slug: "emisar-staff"},
          staff_user
        )

      created

    {:ok, existing} ->
      existing
  end

IO.puts(
  IO.ANSI.cyan() <>
    "✓ Emisar Staff (slug=emisar-staff) — #{staff_email} is_admin; enroll TOTP once for /admin" <>
    IO.ANSI.reset()
)
