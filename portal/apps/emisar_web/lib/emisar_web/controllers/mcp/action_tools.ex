defmodule EmisarWeb.MCP.ActionTools do
  @moduledoc """
  Fixed `run_action` boundary.

  It resolves only exact trusted catalog contracts and exact runner-generation
  references. Model-facing input never chooses a database id or relies on a
  display name. The Runs context remains the policy, approval, audit, and
  persistence authority.
  """

  alias Emisar.{Catalog, Crypto, MCPOperations, Runners}
  alias EmisarWeb.MCP.ActionContract
  alias EmisarWeb.MCP.Attestation
  alias EmisarWeb.MCP.RawJSON
  alias EmisarWeb.MCP.Service
  alias EmisarWeb.MCP.ValidationError

  @doc "Validates and dispatches one exact fixed-catalog action call."
  @spec call(Plug.Conn.t(), map(), binary(), String.t(), [String.t()]) ::
          {:ok, map()} | {:error, map()} | :cancelled
  def call(conn, args, args_raw, operation_id, attestation_headers) do
    input = intake(args, args_raw)

    # The published wait_short pattern mirrors parse_wait's grammar exactly,
    # so a schema-validated wait always parses.
    {:ok, wait_ms} = Service.parse_wait(input.wait)
    fingerprint = operation_fingerprint(input, args_raw)
    operation_attrs = operation_attrs(input, operation_id, fingerprint)

    result =
      run_or_replay(
        conn,
        input,
        args_raw,
        operation_attrs,
        wait_ms,
        attestation_headers
      )

    handle_result(result, input, operation_id)
  end

  defp handle_result(result, input, operation_id) do
    case result do
      {:ok, runs} ->
        {:ok,
         %{
           ok: true,
           operation_id: operation_id,
           action_id: input.action_id,
           pack_ref: input.pack_ref,
           runs: runs
         }}

      {:error, :cancelled} ->
        :cancelled

      {:error, :operation_conflict} ->
        {:error,
         error(
           "operation_conflict",
           "This operation_id already belongs to different action facts."
         )}

      {:error, :operation_incomplete} ->
        {:error,
         error(
           "operation_incomplete",
           "The operation record is incomplete. Reconcile it before retrying.",
           true,
           %{operation_id: operation_id}
         )}

      {:error, :attestation_stale} ->
        {:error,
         error(
           "invalid_attestation",
           "The signed action is outside its runner freshness or certificate window."
         )}

      {:error, :invalid_attestation} ->
        {:error,
         error(
           "invalid_attestation",
           "The signed action header is invalid or does not match this call."
         )}

      {:error, {:signature_required, runner_refs}} ->
        {:error,
         error(
           "signature_required",
           "At least one selected runner requires a signed action call.",
           false,
           %{runner_refs: runner_refs}
         )}

      {:error, reason}
      when reason in [
             :runner_not_found,
             :runner_out_of_scope,
             :action_not_found,
             :action_unavailable,
             :pack_ref_mismatch,
             :pack_untrusted,
             :pack_retired,
             :action_contract_changed
           ] ->
        target_contract_changed(input)

      {:error, :unauthorized} ->
        {:error, error("not_allowed", "This key cannot dispatch actions.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error,
         error(
           "dispatch_failed",
           "The action call failed persistence validation. No target was dispatched.",
           false,
           %{fields: changeset_errors(changeset)}
         )}

      {:error, %{} = payload} ->
        {:error, payload}

      {:error, _reason} ->
        {:error,
         error(
           "dispatch_failed",
           "The action operation could not be committed. No target was dispatched."
         )}
    end
  end

  defp run_or_replay(conn, input, args_raw, operation_attrs, wait_ms, attestation_headers) do
    case MCPOperations.fetch_matching_replay(
           operation_attrs,
           conn.assigns.current_subject
         ) do
      {:ok, operation} ->
        Service.replay_fixed_action(conn, operation, wait_ms)

      {:error, :not_found} ->
        dispatch_new(conn, input, args_raw, operation_attrs, wait_ms, attestation_headers)

      other ->
        other
    end
  end

  defp dispatch_new(conn, input, args_raw, operation_attrs, wait_ms, attestation_headers) do
    with {:ok, targets, action} <- resolve_targets(conn, input),
         :ok <- validate_action_args(input.args, action),
         facts <- attestation_facts(conn, input, args_raw, operation_attrs.operation_id),
         {:ok, attestation} <- Attestation.extract(attestation_headers, facts),
         :ok <- require_attestation_for_enforcing(targets, attestation) do
      intent = %{
        action_id: input.action_id,
        pack_ref: input.pack_ref,
        args: input.args,
        args_raw: args_raw,
        reason: input.reason,
        evidence: input.evidence,
        expected: input.expected,
        operation_attrs: operation_attrs,
        attestation: attestation
      }

      Service.dispatch_fixed_action(conn, targets, intent, wait_ms)
    end
  end

  defp operation_attrs(input, operation_id, fingerprint) do
    %{
      operation_id: operation_id,
      tool: :run_action,
      fingerprint: fingerprint,
      action_id: input.action_id,
      pack_ref: input.pack_ref
    }
  end

  # The controller already validated `args` against the published run_action
  # inputSchema and `args_raw` is the exact, byte-bounded `params.arguments.args`
  # slice RawJSON.tool_call extracted from the same request body, so decoding
  # here preserves exact number spelling for dispatch and cannot fail.
  defp intake(args, args_raw) do
    {:ok, exact_args} = RawJSON.decode_object(args_raw)

    %{
      action_id: args["action_id"],
      pack_ref: args["pack_ref"],
      runner_refs: args["runner_refs"],
      args: exact_args,
      reason: args["reason"],
      # Optional, unenforced justification chain — persisted and rendered for
      # approvers/audit, never a policy/attestation input (so they stay out of
      # the signed facts + operation fingerprint below).
      evidence: args["evidence"],
      expected: args["expected"],
      wait: args["wait"] || "60s"
    }
  end

  defp resolve_targets(conn, input) do
    subject = conn.assigns.current_subject

    with {:ok, runners} <- Runners.list_all_runners_for_account(subject),
         {:ok, actions} <- Catalog.list_all_actions_for_account(subject),
         {:ok, pack_versions} <- Catalog.list_all_pack_versions_for_account(subject) do
      runner_ids = MapSet.new(runners, & &1.id)
      actions = Enum.filter(actions, &MapSet.member?(runner_ids, &1.runner_id))
      snapshot = Catalog.MCPProjection.build(pack_versions, actions, runners)

      with %{} = pack <- Enum.find(snapshot.packs, &(&1.pack_ref == input.pack_ref)),
           %{} = action <- Enum.find(pack.actions, &(&1["action_id"] == input.action_id)),
           {:ok, targets} <- exact_targets(snapshot.runners, action, input.runner_refs) do
        {:ok, targets, action}
      else
        _ -> target_contract_changed(input)
      end
    else
      {:error, :unauthorized} ->
        {:error, error("not_allowed", "This key cannot dispatch actions.")}
    end
  end

  defp validate_action_args(args, action) do
    case ActionContract.validate(args, action) do
      :ok ->
        :ok

      {:error, issue} ->
        path = if issue.code == "unknown_arg", do: [:args], else: [:args, issue.arg]

        {:error,
         ValidationError.payload("Action arguments do not match the trusted contract.",
           stage: :action_arguments,
           issues: [ValidationError.issue(path, issue.code)]
         )}
    end
  end

  defp exact_targets(runners, action, requested_refs) do
    by_ref = Map.new(runners, &{&1.runner_ref, &1})
    compatible_ids = MapSet.new(action.compatible_runner_ids)

    requested_refs
    |> Enum.reduce_while({:ok, []}, fn runner_ref, {:ok, targets} ->
      case Map.get(by_ref, runner_ref) do
        %{id: id} = runner ->
          if MapSet.member?(compatible_ids, id) do
            target = %{
              id: runner.id,
              name: runner.name,
              runner_ref: runner.runner_ref,
              enforce_signatures: runner.enforce_signatures
            }

            {:cont, {:ok, [target | targets]}}
          else
            {:halt, {:error, :target_contract_changed}}
          end

        _ ->
          {:halt, {:error, :target_contract_changed}}
      end
    end)
    |> case do
      {:ok, targets} -> {:ok, Enum.reverse(targets)}
      error -> error
    end
  end

  defp target_contract_changed(input) do
    payload =
      error(
        "target_contract_changed",
        "The selected action contract or runner generation must be refreshed."
      )

    next = %{
      tool: "get_action",
      arguments: %{action_id: input.action_id, pack_ref: input.pack_ref}
    }

    payload =
      payload
      |> put_in([:error, :retryable], true)
      |> put_in([:error, :next], next)

    {:error, payload}
  end

  defp require_attestation_for_enforcing(targets, nil) do
    runner_refs = targets |> Enum.filter(& &1.enforce_signatures) |> Enum.map(& &1.runner_ref)

    if runner_refs == [],
      do: :ok,
      else: {:error, {:signature_required, runner_refs}}
  end

  defp require_attestation_for_enforcing(_targets, _attestation), do: :ok

  defp attestation_facts(conn, input, args_raw, operation_id) do
    %{
      action_id: input.action_id,
      pack_ref: input.pack_ref,
      args_raw: args_raw,
      runner_refs: input.runner_refs,
      reason: input.reason,
      operation_id: operation_id,
      portal_origin: request_origin(conn)
    }
  end

  # URL generation may advertise a public browser origin while a runner or
  # bridge reaches the same portal through a private route. The signed origin is
  # the actual HTTP request origin; the runner independently requires that exact
  # origin to match its local control-plane configuration.
  defp request_origin(conn) do
    %URI{
      scheme: Atom.to_string(conn.scheme),
      host: String.downcase(conn.host),
      port: conn.port
    }
    |> URI.to_string()
  end

  defp operation_fingerprint(input, args_raw) do
    fields = [
      "emisar-mcp-operation-v1",
      "run_action",
      input.action_id,
      input.pack_ref,
      Crypto.hash_hex(args_raw),
      input.reason | Enum.sort(input.runner_refs)
    ]

    fields
    |> Enum.map_join(fn value -> Integer.to_string(byte_size(value)) <> ":" <> value end)
    |> Crypto.hash_hex()
  end

  defp error(code, message, dispatch_started \\ false, details \\ nil)

  defp error(code, message, dispatch_started, details) do
    error = %{code: code, message: message, retryable: false}
    error = if details, do: Map.put(error, :details, details), else: error
    %{ok: false, error: error, dispatch_started: dispatch_started}
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, rendered ->
        String.replace(rendered, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
