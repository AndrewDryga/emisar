defmodule Emisar.Seeds.Fleet do
  @moduledoc """
  The demo fleet: four production-shaped runners, the catalog each one
  advertises, one teammate per shape a runner grant can take, and the bootstrap
  enrollment key (seeded last by the driver, so its curl line prints last).
  """

  alias Emisar.Accounts
  alias Emisar.Audit
  alias Emisar.Catalog
  alias Emisar.Catalog.{PackBaseline, PackVersion}
  alias Emisar.Repo
  alias Emisar.Runners
  alias Emisar.Runners.Runner
  alias Emisar.Seeds.{DemoAccount, Helpers}
  alias Emisar.Users.User

  @doc "Adds `runners`, `sam`, and `wren` to the context."
  def run(ctx) do
    runners =
      Enum.map(runner_specs(), fn spec ->
        ctx |> ensure_runner(spec) |> stamp_runner_state(spec)
      end)

    Helpers.say(
      "✓ Seeded #{length(runners)} demo runners (3 adopted by docker containers on boot, 1 offline)"
    )

    advertise_catalog(ctx, runners)
    {sam, wren} = seed_member_access_shapes(ctx)
    backdate_joins(ctx, sam, wren)

    Map.merge(ctx, %{runners: runners, sam: sam, wren: wren})
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
  defp runner_specs do
    [
      %{
        name: "edge-fra-01",
        external_id: "edge-fra-01",
        group: "edge-web",
        hostname: "edge-fra-01.northstar.example",
        labels: %{"env" => "prod", "region" => "eu-central", "role" => "edge"},
        state: :connected,
        version: Emisar.Compat.runner_target(),
        last_seen_min: 2
      },
      %{
        name: "api-iad-02",
        external_id: "api-iad-02",
        group: "app-api",
        hostname: "api-iad-02.northstar.example",
        labels: %{"env" => "prod", "region" => "us-east-1", "service" => "checkout"},
        state: :connected,
        version: Emisar.Compat.runner_target(),
        last_seen_min: 4
      },
      %{
        name: "pg-primary-iad",
        external_id: "pg-primary-iad",
        group: "data-postgres",
        hostname: "pg-primary-iad.northstar.example",
        labels: %{"env" => "prod", "region" => "us-east-1", "role" => "primary"},
        state: :connected,
        version: Emisar.Compat.runner_target(),
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
        version: Emisar.Compat.runner_target(),
        last_seen_min: 140
      }
    ]
  end

  defp ensure_runner(%{account: account, owner_subject: owner_subject}, spec) do
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
          Helpers.insert_seed_runner(
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

  @doc """
  Puts a runner back onto its seeded last-seen history after a preflight
  connection took it over.
  """
  def restore_runner_state(%Runner{} = runner) do
    spec = Enum.find(runner_specs(), &(&1.name == runner.name))
    stamp_runner_state(runner, spec)
  end

  defp stamp_runner_state(runner, spec) do
    # Connection state is Phoenix.Presence — it can't be seeded (no live
    # socket), so we backdate the durable "last seen" history only. The three
    # :connected rows flip to truly online the moment their docker container
    # adopts them (matched by external_id); the :disconnected row has no
    # container, so it stays offline with this last-seen + disconnect reason.
    seen_at = Helpers.mins_ago(spec.last_seen_min)

    attrs =
      case spec.state do
        :connected ->
          %{last_connected_at: seen_at}

        :disconnected ->
          %{
            last_connected_at: Helpers.mins_ago(spec.last_seen_min + 60),
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

  # -- Catalog: actions on each runner ---------------------------------

  @doc "The on-host baseline every demo runner advertises."
  def linux_actions do
    [
      Helpers.action_descriptor("linux-core", %{
        "id" => "linux.uptime",
        "title" => "System uptime and load average",
        "risk" => "low",
        "description" => "Reports system uptime and 1/5/15-minute load averages.",
        "args" => []
      }),
      Helpers.action_descriptor("linux-core", %{
        "id" => "linux.disk_usage",
        "title" => "Filesystem disk usage",
        "risk" => "low",
        "description" => "Reports filesystem usage for supplied paths using df.",
        "args" => [
          %{"name" => "paths", "type" => "string_array", "required" => false}
        ]
      }),
      Helpers.action_descriptor("linux-core", %{
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
  end

  defp api_actions do
    [
      Helpers.action_descriptor("systemd-deep", %{
        "id" => "systemd.failed_units",
        "title" => "Failed systemd units",
        "risk" => "low",
        "description" => "Lists units not in active state with their last failure reason.",
        "args" => []
      }),
      Helpers.action_descriptor("systemd-deep", %{
        "id" => "systemd.unit_show",
        "title" => "systemctl show <unit>",
        "risk" => "high",
        "description" => "Shows systemd properties for one unit.",
        "args" => [%{"name" => "unit", "type" => "string", "required" => true}]
      }),
      # The unit lifecycle lives in linux-core, so the API host carries that
      # pack's restart beside the systemd-deep reads; the pending approval and
      # the old cancellation in the run history both dispatch it.
      Helpers.action_descriptor("linux-core", %{
        "id" => "linux.systemctl_restart",
        "title" => "Restart a systemd unit",
        "risk" => "high",
        "description" =>
          "Restart a named systemd unit. Clients see an outage of seconds to " <>
            "minutes depending on the unit; prefer diagnosis first.",
        "side_effects" => [
          "Stops the named unit, then starts it.",
          "Disconnects existing clients of the unit."
        ],
        "args" => [%{"name" => "unit", "type" => "string", "required" => true}]
      })
    ]
  end

  defp postgres_actions do
    [
      Helpers.action_descriptor("postgres", %{
        "id" => "postgres.replication_lag",
        "title" => "Replication lag (primary view)",
        "risk" => "low",
        "description" => "Reports replication slot health from the primary's perspective.",
        "args" => []
      }),
      Helpers.action_descriptor("postgres", %{
        "id" => "postgres.vacuum_status",
        "title" => "Autovacuum + bloat snapshot",
        "risk" => "low",
        "description" => "Returns dead-tuple counts and vacuum timestamps by table.",
        "args" => [
          %{"name" => "schema", "type" => "string", "required" => false},
          %{"name" => "limit", "type" => "integer", "required" => false}
        ]
      }),
      Helpers.action_descriptor("postgres", %{
        "id" => "postgres.reload_conf",
        "title" => "Reload postgresql.conf",
        "risk" => "high",
        "description" => "Calls pg_reload_conf() to re-read server config.",
        "side_effects" => ["Server re-reads postgresql.conf and pg_hba.conf."],
        "args" => []
      })
    ]
  end

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
  @doc "Pack versions the demo fleet advertises behind the shipped current one."
  def pack_version_overrides do
    %{"postgres" => PackBaseline.previous_version("postgres")}
  end

  defp advertise_catalog(%{account: account}, runners) do
    edge_actions = Helpers.baseline_action_descriptors("caddy")

    # The checkout tier runs in containers, so the API host carries the docker pack
    # too. The typed JSON demo run dispatches docker.compose_config on it.
    docker_actions = Helpers.baseline_action_descriptors("docker")

    Enum.each(runners, fn r ->
      case r.group do
        "edge-web" -> advertise(r, edge_actions ++ linux_actions())
        "app-api" -> advertise(r, api_actions() ++ docker_actions ++ linux_actions())
        "data-postgres" -> advertise(r, postgres_actions() ++ linux_actions())
        _ -> advertise(r, linux_actions())
      end
    end)

    PackVersion.Query.all()
    |> PackVersion.Query.by_account_id(account.id)
    |> PackVersion.Query.by_pack_id("showcase")
    |> Repo.delete_all()

    Helpers.say(
      "✓ Advertised actions on every runner (postgres one version behind → update-available hint)"
    )
  end

  @doc "Records `actions` as the catalog `runner` advertises, unless it already advertised one."
  def advertise(%Runner{} = runner, actions) do
    overrides = pack_version_overrides()

    packs =
      actions
      |> Enum.map(& &1["pack_id"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Map.new(fn pack_id ->
        {pack_id, Helpers.pack_descriptor(pack_id, overrides[pack_id])}
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

  # -- Member access shapes ---------------------------------------------
  #
  # The roster is where a grant has to READ correctly, so seed one member per
  # shape it can take: every runner, a group plus one exact host, several groups
  # narrowed to named packs, and every runner narrowed to a single pack. Runs
  # after the catalog because a pack selection is allowlisted against the pack ids
  # the account actually carries.
  defp seed_member_access_shapes(%{owner_subject: owner_subject, priya: priya} = ctx) do
    {:ok, scope_runners} = Runners.list_all_runners_for_account(owner_subject)
    {:ok, scope_packs} = Catalog.list_account_pack_ids(owner_subject)
    allowlist = Accounts.runner_access_allowlist(scope_runners, scope_packs)

    # A group plus one exact host from a different group — the shape a picker
    # collapses wrongly if it lets a group and its own members both be checked.
    set_member_access(
      ctx,
      allowlist,
      priya,
      "restricted",
      ["group:edge-web", runner_ref(scope_runners, "api-iad-02")],
      "all",
      []
    )

    sam = DemoAccount.invite_member(ctx, "sam@emisar.dev", "Sam Okafor", "operator")

    set_member_access(
      ctx,
      allowlist,
      sam,
      "restricted",
      ["group:edge-web", "group:data-postgres"],
      "restricted",
      ["pack:linux-core", "pack:postgres"]
    )

    # Every runner, one pack: the "may look at Postgres anywhere, may not open a
    # shell" grant that runner groups alone cannot express.
    wren = DemoAccount.invite_member(ctx, "wren@emisar.dev", "Wren Alvarez", "viewer")
    set_member_access(ctx, allowlist, wren, "all", [], "restricted", ["pack:postgres"])

    Helpers.say(
      "✓ Member access shapes: Jordan (all), Priya (group + host), Sam (2 groups, 2 packs), Wren (all runners, 1 pack)"
    )

    {sam, wren}
  end

  defp runner_ref(scope_runners, name) do
    case Enum.find(scope_runners, &(&1.name == name)) do
      nil -> raise "seed runner #{name} is missing — member access shapes seed after the fleet"
      runner -> "runner:" <> runner.id
    end
  end

  defp set_member_access(
         %{account: account, owner_subject: owner_subject},
         allowlist,
         %User{} = member,
         mode,
         scope,
         pack_mode,
         pack_scope
       ) do
    membership = Accounts.peek_sync_membership(account.id, member.id)

    {:ok, access} = Accounts.build_runner_access(mode, scope, allowlist, pack_mode, pack_scope)

    {:ok, _membership} =
      Accounts.update_membership_runner_access(membership, access, owner_subject)
  end

  # The roster orders newest-joined first, and "joined" is the membership row's
  # inserted_at — so a team stamped at seed time all reads "joined 1m ago", which
  # is the fixture showing through. Weeks-old, staggered joins put the standing
  # team in a sensible order; the SCIM directory batch (seeded near the end, when
  # enabled) backdates itself behind them.
  defp backdate_joins(%{account: account, user: user, jordan: jordan, priya: priya}, sam, wren) do
    [
      {user.id, Helpers.days_ago(42)},
      {jordan.id, Helpers.days_ago(35)},
      {priya.id, Helpers.days_ago(28)},
      {sam.id, Helpers.days_ago(21)},
      {wren.id, Helpers.days_ago(12)}
    ]
    |> Enum.each(fn {member_user_id, joined_at} ->
      case Accounts.peek_sync_membership(account.id, member_user_id) do
        nil ->
          :ok

        membership ->
          membership
          |> Ecto.Changeset.change(inserted_at: joined_at, invitation_accepted_at: joined_at)
          |> Repo.update!()
      end
    end)
  end

  # -- Bootstrap enrollment key ------------------------------------------

  @doc "Seeds the account's first enrollment key and prints how to bootstrap a runner with it."
  def seed_enrollment_key(%{account: account, user: user, owner_subject: owner_subject}) do
    case Runners.list_enrollment_keys(owner_subject) do
      {:ok, [], _} ->
        case System.get_env("EMISAR_DEV_FIXED_ENROLLMENT_KEY") do
          fixed when is_binary(fixed) and byte_size(fixed) >= 29 ->
            {:ok, _key} =
              Runners.EnrollmentKey.Changeset.create_with_secret(account.id, user.id, fixed, %{
                description: "Dev fixed enrollment key (docker-compose)",
                group: "dev-docker",
                reusable: true
              })
              |> Repo.insert()

            Helpers.say("✓ Seeded dev fixed enrollment key", IO.ANSI.green())

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
            Helpers.say("Bootstrap a runner:", IO.ANSI.green())

            IO.puts(
              "  curl -fsSL https://emisar.dev/install.sh | sudo EMISAR_ENROLLMENT_KEY=#{raw} bash"
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
  end
end
