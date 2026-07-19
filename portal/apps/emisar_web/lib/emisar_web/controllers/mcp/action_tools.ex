defmodule EmisarWeb.MCP.ActionTools do
  @moduledoc """
  Fixed `run_action` boundary.

  It resolves only exact trusted catalog contracts and exact runner-generation
  references. Model-facing input never chooses a database id or relies on a
  display name. The Runs context remains the policy, approval, audit, and
  persistence authority.
  """

  alias Emisar.{Catalog, Crypto, MCPOperations, Runners}
  alias EmisarWeb.MCP.{ActionContract, Attestation, RawJSON, Service}

  @required ~w(action_id pack_ref runner_refs args reason)
  @allowed @required ++ ~w(wait)
  @action_id ~r/\A[a-z][a-z0-9_-]*(?:\.[a-z][a-z0-9_-]*)+\z/
  @operation_id ~r/\Aop_[0-7][0-9A-HJKMNP-TV-Z]{25}\z/
  @max_runner_refs 16

  @doc "Validates and dispatches one exact fixed-catalog action call."
  @spec call(Plug.Conn.t(), map(), binary(), String.t(), [String.t()]) ::
          {:ok, map()} | {:error, map()} | :cancelled
  def call(conn, args, args_raw, operation_id, attestation_headers) do
    with {:ok, input} <- validate(args, args_raw, operation_id),
         {:ok, wait_ms} <- parse_wait(input.wait),
         fingerprint <- operation_fingerprint(input, args_raw),
         operation_attrs <- operation_attrs(input, operation_id, fingerprint),
         result <-
           run_or_replay(
             conn,
             input,
             args_raw,
             operation_attrs,
             wait_ms,
             attestation_headers
           ) do
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
               :pack_ref_mismatch,
               :pack_untrusted,
               :pack_retired
             ] ->
          target_contract_changed(input)

        {:error, :unauthorized} ->
          {:error, error("not_allowed", "This key cannot dispatch actions.")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error,
           error("invalid_args", "The action call failed persistence validation.", false, %{
             fields: changeset_errors(changeset)
           })}

        {:error, %{} = payload} ->
          {:error, payload}

        {:error, _reason} ->
          {:error,
           error(
             "dispatch_failed",
             "The action operation could not be committed. No target was dispatched."
           )}
      end
    else
      {:error, %{} = payload} ->
        {:error, payload}

      {:error, :invalid_wait} ->
        {:error, error("invalid_args", "wait must be 0 or a duration no longer than 60s.")}
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

  defp validate(args, args_raw, operation_id) when is_map(args) and is_binary(args_raw) do
    with :ok <- exact_fields(args),
         true <- is_binary(args["action_id"]) and Regex.match?(@action_id, args["action_id"]),
         {:ok, _parts} <- Catalog.MCPProjection.parse_pack_ref(args["pack_ref"]),
         {:ok, runner_refs} <- runner_refs(args["runner_refs"]),
         true <- is_map(args["args"]),
         true <- byte_size(args_raw) <= 32_768,
         {:ok, exact_args} <- RawJSON.decode_object(args_raw),
         true <- valid_reason?(args["reason"]),
         true <- is_binary(operation_id) and Regex.match?(@operation_id, operation_id),
         true <- is_nil(args["wait"]) or is_binary(args["wait"]) do
      {:ok,
       %{
         action_id: args["action_id"],
         pack_ref: args["pack_ref"],
         runner_refs: runner_refs,
         args: exact_args,
         reason: args["reason"],
         wait: args["wait"] || "60s"
       }}
    else
      _ ->
        {:error, error("invalid_args", "run_action arguments do not match the fixed contract.")}
    end
  end

  defp validate(_args, _args_raw, _operation_id),
    do: {:error, error("invalid_args", "run_action arguments do not match the fixed contract.")}

  defp exact_fields(args) do
    keys = Map.keys(args)

    if Enum.all?(@required, &Map.has_key?(args, &1)) and Enum.all?(keys, &(&1 in @allowed)),
      do: :ok,
      else: {:error, :invalid_args}
  end

  defp runner_refs(refs) when is_list(refs) and length(refs) in 1..@max_runner_refs do
    if Enum.all?(refs, &(is_binary(&1) and byte_size(&1) in 1..113)) and
         MapSet.size(MapSet.new(refs)) == length(refs) do
      {:ok, refs}
    else
      {:error, :invalid_runner_refs}
    end
  end

  defp runner_refs(_refs), do: {:error, :invalid_runner_refs}

  defp valid_reason?(reason),
    do: is_binary(reason) and byte_size(reason) in 1..255 and String.trim(reason) != ""

  defp parse_wait(wait) do
    case Service.parse_wait(wait) do
      {:ok, wait_ms} -> {:ok, wait_ms}
      :error -> {:error, :invalid_wait}
    end
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
        {:error,
         error("invalid_args", "Action arguments do not match the trusted contract.", false, %{
           fields: %{issue.arg => %{code: issue.code, message: issue.message}}
         })}
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
        "The selected action, pack, or runner generation is no longer executable."
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

  defp error(code, message, dispatch_started \\ false, details \\ nil) do
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
