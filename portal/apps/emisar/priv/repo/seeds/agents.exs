defmodule Emisar.Seeds.Agents do
  @moduledoc """
  The demo account's API keys: the LLM-bridge key the historical MCP runs are
  attributed to, a realistic fleet of agent keys across clients and owners
  (one rotation still mid-swap), and the audit-export token.
  """

  alias Emisar.Accounts
  alias Emisar.ApiKeys
  alias Emisar.Repo
  alias Emisar.Seeds.Helpers

  @doc "Adds `agent_key` — the MCP key the seeded agent runs are attributed to — to the context."
  def run(ctx) do
    agent_key = seed_bridge_key(ctx)
    seed_agent_fleet(ctx)
    seed_export_key(ctx)
    Map.put(ctx, :agent_key, agent_key)
  end

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
  defp seed_bridge_key(%{
         account: account,
         user: user,
         owner_membership: owner_membership,
         owner_subject: owner_subject
       }) do
    agent_key_name = "Claude Code"

    agent_key_attrs = %{
      name: agent_key_name,
      description:
        "MCP bridge used by the on-call engineer for read-only triage and " <>
          "approval-gated remediation."
    }

    agent_key = Enum.find(Helpers.account_api_keys(account), &(&1.name == agent_key_name))

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
            expires_at: Helpers.days_out(30),
            revoked_at: nil,
            revoked_by_id: nil,
            replaces_id: nil,
            rotated_to_id: nil
          )
          |> Repo.update!()
      end
      |> Ecto.Changeset.change(
        last_used_at: Helpers.mins_ago(9),
        # What Claude Code actually reports at `initialize` (clientInfo) plus the
        # emisar-mcp bridge version the portal reads off the UA — not a hand-faked
        # label. name is the machine id, title the human one, version the client's
        # own release, bridge_version the stdio bridge's.
        last_client_info: %{
          "name" => "claude-code",
          "title" => "Claude Code",
          "version" => "2.1.4",
          "bridge_version" => Emisar.Compat.mcp_target()
        }
      )
      |> Repo.update!()

    Helpers.say("✓ Seeded MCP API key for the LLM agent")

    agent_key
  end

  # -- A realistic agent fleet ----------------------------------------
  #
  # More MCP keys so the agents page shows the spread operators really see:
  # different clients (each reports its own clientInfo at `initialize`),
  # different owners (the list groups by the issuing human), a range of
  # liveness states, and a rotation still mid-swap. Built directly (§7 seed style) and idempotent by
  # (name, owner) so re-seeding converges the state instead of duplicating.
  #
  # Read from Compat rather than pinning a literal: a pinned bridge version
  # starts earning the "outdated" nudge — and eventually the rose "unsupported"
  # chip plus the fleet-wide upgrade notice — the day the target moves, and the
  # default demo account has to read healthy.
  defp seed_agent_fleet(
         %{account: account, user: user, owner_membership: owner_membership, jordan: jordan} =
           ctx
       ) do
    mcp_bridge_current = Emisar.Compat.mcp_target()
    jordan_membership = Accounts.peek_sync_membership(account.id, jordan.id)

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
       }, Helpers.mins_ago(3), Helpers.days_out(30)},
      # Remote OAuth (ChatGPT): it initialized — so it reports a client — but no
      # tracked call has landed yet → "never used". No bridge (remote), and OAuth
      # owns its lifecycle so there is no static expiry.
      {user, owner_membership.id, "ChatGPT", %{"name" => "openai-mcp (ChatGPT)"}, nil, nil},
      # A second owner's key, so the list gains a second owner group. Codex reports
      # a short "Codex" title that differs from the key name → the client seg stays.
      {jordan, jordan_membership.id, "Codex CLI",
       %{"name" => "Codex", "version" => "0.9.2", "bridge_version" => mcp_bridge_current},
       Helpers.mins_ago(6), Helpers.days_out(30)},
      # A minimal client initialize — no title, no client version — still renders.
      {jordan, jordan_membership.id, "Gemini CLI",
       %{"name" => "gemini-cli-mcp-client", "bridge_version" => mcp_bridge_current},
       Helpers.hours_ago(1), Helpers.days_out(29)},
      # Drift: a key named for one client but actually driven by another (Claude
      # Code), gone quiet for weeks → dormant. Here the client seg earns its place —
      # the name alone would mislead.
      {jordan, jordan_membership.id, "Claude Desktop",
       %{
         "name" => "claude-code",
         "title" => "Claude Code",
         "bridge_version" => mcp_bridge_current
       }, Helpers.days_ago(17), Helpers.days_out(13)}
    ]
    |> Enum.each(fn {owner_user, membership_id, name, client_info, used_at, expires_at} ->
      seed_agent_key(ctx, owner_user, membership_id, name, client_info, used_at, expires_at)
    end)

    seed_mid_swap_rotation(ctx, mcp_bridge_current)

    Helpers.say("✓ Seeded the agent fleet (multiple clients + owners, a mid-swap rotation)")
  end

  # Build (or converge) one agent key directly under a given member. Idempotent
  # by (name, owner): a re-seed updates the liveness/client state rather than
  # minting a duplicate. `client_info` mirrors what that client's `initialize`
  # records; `used_at`/`expires_at` set the row's liveness the way real calls do.
  defp seed_agent_key(
         %{account: account},
         owner_user,
         owner_membership_id,
         name,
         client_info,
         used_at,
         expires_at
       ) do
    existing =
      Enum.find(
        Helpers.account_api_keys(account),
        &(&1.name == name and &1.created_by_id == owner_user.id)
      )

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

  # A rotation still mid-swap: the operator rotated "Cursor", so a successor
  # exists, but its first call hasn't landed — the predecessor keeps working until
  # it does. The list shows the successor's amber "replaces … · swap pending".
  defp seed_mid_swap_rotation(
         %{account: account, user: user, owner_membership: owner_membership},
         mcp_bridge_current
       ) do
    cursor_keys =
      Enum.filter(
        Helpers.account_api_keys(account),
        &(&1.name == "Cursor" and &1.created_by_id == user.id)
      )

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
        last_used_at: Helpers.days_ago(2),
        last_client_info: cursor_client,
        expires_at: Helpers.days_out(20),
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
      expires_at: Helpers.days_out(30),
      revoked_at: nil
    )
    |> Repo.update!()

    cursor_predecessor
    |> Ecto.Changeset.change(rotated_to_id: cursor_successor.id)
    |> Repo.update!()
  end

  # -- Audit-export key ------------------------------------------------
  #
  # Mirrors the "Mint export token" button on the audit page so a
  # freshly-seeded demo account already shows what the SIEM workflow
  # looks like — a separate token on the audit page whose `:audit_export`
  # kind can reach only the read-only audit endpoint.
  defp seed_export_key(%{account: account, owner_subject: owner_subject}) do
    export_key_name = "SIEM export - Datadog intake"

    export_key = Enum.find(Helpers.account_api_keys(account), &(&1.name == export_key_name))

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
    |> Ecto.Changeset.change(last_used_at: Helpers.hours_ago(6))
    |> Repo.update!()

    Helpers.say("✓ Seeded audit-export API key")
  end
end
