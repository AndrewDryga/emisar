defmodule Emisar.Fixtures.Runs do
  @moduledoc """
  Action-run test fixtures. Use via `alias Emisar.Fixtures`.
  """

  import Ecto.Changeset, only: [change: 2]
  alias Emisar.{Crypto, Fixtures, Repo, Runs}
  alias Emisar.Runners.Runner
  alias Emisar.Runs.{ActionRun, Attestation}

  @default_pack_ref "linux-core@1.0.0/sha256:" <> String.duplicate("a", 64)
  @default_operation_id "op_724NN9NMDZ1T76NARWCKM5A0D6"

  @doc """
  Persists a `:success` action run by default. Caller supplies `:account_id`
  (a runner is created in it) or nothing (a fresh account + runner). Override
  `:status`, `:action_id`, `:source`, `:request_id`, `:args_raw`,
  `:sensitive_arg_names`, `:expected_pack_hash`, `:inserted_at` (to land a run
  in a report window), and `:sent_at` (to model work handed to a runner) as
  needed.
  """
  def create_run(attrs \\ %{}) do
    attrs = Map.new(attrs)

    runner =
      if attrs[:runner_id],
        do: nil,
        else: Fixtures.Runners.create_runner(Map.take(attrs, [:account_id]))

    params = %{
      account_id: attrs[:account_id] || runner.account_id,
      runner_id: attrs[:runner_id] || runner.id,
      request_id: attrs[:request_id] || Crypto.run_request_id(),
      action_id: attrs[:action_id] || "svc.read",
      source: attrs[:source] || :operator,
      status: attrs[:status] || :success,
      args_raw: attrs[:args_raw] || "{}",
      sensitive_arg_names: attrs[:sensitive_arg_names] || [],
      expected_pack_hash: attrs[:expected_pack_hash]
    }

    {:ok, run} = params |> ActionRun.Changeset.create() |> Repo.insert()

    overrides =
      %{}
      |> maybe_put_datetime(:inserted_at, attrs[:inserted_at])
      |> maybe_put_datetime(:sent_at, attrs[:sent_at])

    if overrides == %{}, do: run, else: run |> change(overrides) |> Repo.update!()
  end

  defp maybe_put_datetime(attrs, key, %DateTime{} = value), do: Map.put(attrs, key, value)
  defp maybe_put_datetime(attrs, _key, _value), do: attrs

  @doc """
  Replaces a run's stored argument bytes with a payload the create changeset
  would have rejected, so a display path can be driven against arguments that
  were corrupted after the write. Writes the column straight onto the row — a
  fixture builds rows without a Subject.
  """
  def put_malformed_args_raw(%ActionRun{} = run, args_raw) when is_binary(args_raw) do
    run
    |> change(args_raw: args_raw)
    |> Repo.update!()
  end

  @doc """
  Pre-spend a run's durable progress budget (`:events` / `:bytes`) so a
  boundary test can drive the ceiling without appending tens of thousands of
  real chunks. Writes the counters straight onto the row — a fixture builds
  rows without a Subject.
  """
  def charge_progress_budget(%ActionRun{} = run, opts \\ []) do
    run
    |> change(
      progress_event_count: Keyword.get(opts, :events, 0),
      progress_byte_count: Keyword.get(opts, :bytes, 0)
    )
    |> Repo.update!()
  end

  @doc """
  Places a run in an in-flight status for query and timeout setup. It does not
  claim runner-connection ownership; tests of runner messages use the real
  connection-owned APIs.
  """
  def put_status(%ActionRun{} = run, :sent) do
    run
    |> ActionRun.Changeset.transition(:sent, %{sent_at: DateTime.utc_now()})
    |> Repo.update!()
  end

  def put_status(%ActionRun{} = run, :running) do
    now = DateTime.utc_now()

    run
    |> ActionRun.Changeset.transition(:running, %{sent_at: run.sent_at || now, started_at: now})
    |> Repo.update!()
  end

  @doc "Finalizes a run through the same connection-owned path as a runner result."
  def finish(%ActionRun{} = run, payload) when is_map(payload) do
    runner = Repo.get!(Runner, run.runner_id)
    payload = Map.put(payload, "request_id", run.request_id)

    Runs.finalize_from_connection(
      run.account_id,
      runner.id,
      runner.connection_generation,
      runner.connection_lease_id,
      payload
    )
  end

  @doc """
  Persists a terminal runner result without invoking the post-commit runbook
  callback. This models a process loss after the ActionRun transaction commits
  and before the scheduler sees the terminal attempt.
  """
  def finish_without_runbook_callback(%ActionRun{} = run, status, structured_output)
      when status in [:success, :failed] and is_map(structured_output) do
    run
    |> Repo.reload!()
    |> ActionRun.Changeset.transition(status, %{
      finished_at: DateTime.utc_now(),
      structured_output: structured_output
    })
    |> Repo.update!()
  end

  @doc """
  Builds one bridge-signed v4 attestation for a dispatch and returns
  `%{header: encoded, envelope: normalized, attestation: validated}` — the
  `Emisar-Attestation` header a signed MCP call sends, the envelope the portal
  persists and relays, and the validated value dispatch attrs carry.

  Override any bound fact (`:action_id`, `:pack_ref`, `:args_raw`,
  `:runner_refs`, `:reason`, `:operation_id`, `:portal_origin`), the certificate
  identity (`:ca_id`, `:key_id`), or either window bound (`:issued_at`,
  `:valid_until`).
  """
  def signed_attestation(attrs \\ %{}) do
    attrs = Map.new(attrs)
    now = DateTime.utc_now()

    facts = %{
      action_id: attrs[:action_id] || "linux.uptime",
      pack_ref: attrs[:pack_ref] || @default_pack_ref,
      args_raw: attrs[:args_raw] || "{}",
      runner_refs: attrs[:runner_refs] || ["runner~" <> String.duplicate("0", 32)],
      reason: attrs[:reason] || "test",
      evidence: attrs[:evidence],
      expected: attrs[:expected],
      operation_id: attrs[:operation_id] || @default_operation_id,
      portal_origin: attrs[:portal_origin] || "https://portal.example"
    }

    envelope = %{
      "version" => "emisar-attestation-v5",
      "tool" => "run_action",
      "portal_origin" => facts.portal_origin,
      "action_id" => facts.action_id,
      "pack_ref" => facts.pack_ref,
      "args_sha256" => Crypto.hash_hex(facts.args_raw),
      "runner_refs" => Enum.sort(facts.runner_refs),
      "reason" => facts.reason,
      "evidence_sha256" => Crypto.hash_hex(facts.evidence || ""),
      "expected_sha256" => Crypto.hash_hex(facts.expected || ""),
      "operation_id" => facts.operation_id,
      "sig" => String.duplicate("1", 128),
      "nonce" => String.duplicate("2", 32),
      "issued_at" => attrs[:issued_at] || DateTime.to_iso8601(now),
      "cert_chain" => [
        Emisar.Fixtures.Certificates.leaf_chain_entry(
          attrs[:valid_until] || DateTime.add(now, 86_400, :second)
        )
      ]
    }

    header = envelope |> Jason.encode!() |> Base.url_encode64(padding: false)
    {:ok, attestation} = Attestation.validate([header], facts)

    %{header: header, envelope: envelope, attestation: attestation}
  end

  @doc """
  Persists a run row carrying a validated `:attestation` from
  `signed_attestation/1`.

  Only the preflighted MCP fan-out mints signed state through the domain, so an
  approval or audit setup that needs a persisted signed row builds it here — a
  fixture writes rows directly rather than reaching for a context escape hatch.
  """
  def create_signed_run(attrs) do
    attrs = Map.new(attrs)
    %Attestation{} = Map.fetch!(attrs, :attestation)

    attrs
    |> Map.put_new(:request_id, Crypto.run_request_id())
    |> Map.put_new(:queued_at, DateTime.utc_now())
    |> ActionRun.Changeset.create()
    |> Repo.insert!()
  end
end
