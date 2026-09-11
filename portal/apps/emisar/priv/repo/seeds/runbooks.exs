defmodule Emisar.Seeds.Runbooks do
  @moduledoc """
  The demo account's runbooks: a readiness check with no history, the edge
  configuration rollout every execution story runs, and the TLS rotation whose
  executions keep a visible approval backlog.
  """

  alias Emisar.Repo
  alias Emisar.Runbooks
  alias Emisar.Runbooks.{Release, Runbook}
  alias Emisar.Seeds.Helpers

  @morning_definition %{
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

  @approval_definition %{
    "schema_version" => 1,
    "context_markdown" =>
      "## Change window\n\n" <>
        "- Confirm the candidate config has passed `caddy validate`.\n" <>
        "- Keep the incident channel open during the reload.\n\n" <>
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

  @doc "Adds `approval_runbook` and `backlog_runbook` to the context."
  def run(ctx) do
    _morning_runbook =
      seed_live_runbook(ctx, "morning-edge-readiness", %{
        slug: "morning-edge-readiness",
        title: "Morning edge readiness",
        description:
          "08:00 UTC check across the edge-web group before the EU traffic peak: " <>
            "host load, disk pressure, and memory health.",
        draft_definition: @morning_definition
      })

    Helpers.say("✓ Seeded empty-history sample runbook")

    approval_runbook =
      seed_live_runbook(ctx, "edge-configuration-rollout", %{
        slug: "edge-configuration-rollout",
        title: "Edge configuration rollout",
        description:
          "Reload a validated Caddy configuration across the edge fleet, " <>
            "then verify the running version and upstream health.",
        draft_definition: @approval_definition
      })

    # The guide follows this one procedure end to end, so the unpublished change it
    # documents lives here: reload the two edge nodes one at a time instead of
    # together. ONE scalar edit on purpose — the published diff has to be legible in
    # a docs screenshot, and a JSON line diff cannot wrap, so editing a long string
    # value (context_markdown) produces a truncated pair that shows the reader
    # nothing.
    approval_draft_definition =
      put_in(@approval_definition, ["stages", Access.at(0), "max_parallel"], 1)

    {:ok, _approval_draft} =
      approval_runbook
      |> Runbook.Changeset.draft(%{draft_definition: approval_draft_definition})
      |> Repo.update()

    Helpers.say("✓ Seeded edge configuration rollout runbook")

    # A couple of runbook executions waiting on an approver keep a small, believable
    # queue on Approvals. An execution awaiting approval creates no action runs, so
    # the queue rows never touch the runs list.
    backlog_runbook =
      seed_live_runbook(ctx, "rotate-edge-tls-certificates", %{
        slug: "rotate-edge-tls-certificates",
        title: "Rotate edge TLS certificates",
        description:
          "Reload the edge fleet onto freshly issued certificates. Every run waits " <>
            "for an approver, which is what keeps a visible backlog on this account.",
        draft_definition: @approval_definition
      })

    Helpers.say("✓ Seeded edge TLS rotation runbook")

    Map.merge(ctx, %{approval_runbook: approval_runbook, backlog_runbook: backlog_runbook})
  end

  defp seed_live_runbook(%{account: account, user: user}, slug, attrs) do
    runbook =
      case Helpers.peek_account_runbook(account, slug) do
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
      publish_seeded_runbook(runbook)
    end
  end

  # Publication is arranged at the changeset level: the demo runners these
  # runbooks target are seeded next, so the context's current-state publication
  # readiness cannot pass yet.
  defp publish_seeded_runbook(%Runbook{} = runbook) do
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
end
