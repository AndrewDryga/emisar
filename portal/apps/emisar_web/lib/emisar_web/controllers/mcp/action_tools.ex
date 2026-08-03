defmodule EmisarWeb.MCP.ActionTools do
  @moduledoc """
  Fixed `run_action` boundary.

  It parses model-facing input without accepting database ids or display names.
  The Runs context resolves exact trusted catalog contracts and runner-generation
  references, and remains the policy, approval, audit, signature-binding, and
  persistence authority.
  """

  alias Emisar.RawJSON
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
    facts = action_facts(conn, input, operation_id, attestation_headers)
    result = Service.dispatch_fixed_action(conn, facts, wait_ms)

    handle_result(conn, result, input, operation_id)
  end

  defp handle_result(conn, result, input, operation_id) do
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

      {:error, {:invalid_action_arguments, issue}} ->
        {:error, invalid_action_arguments(issue)}

      {:error, reason}
      when reason in [
             :runner_not_found,
             :runner_out_of_scope,
             :action_not_found,
             :action_unavailable,
             :pack_ref_mismatch,
             :pack_untrusted,
             :pack_retired,
             :action_contract_changed,
             :target_contract_changed
           ] ->
        target_contract_changed(conn, input)

      {:error, :unauthorized} ->
        not_allowed(conn, input)

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

  # Runs owns identity, replay, target resolution, contract validation, and the
  # envelope's binding. The boundary contributes only what it alone knows: the
  # exact request bytes, the raw signature header, and the actual request origin
  # the client signed over.
  defp action_facts(conn, input, operation_id, attestation_headers) do
    %{
      operation_id: operation_id,
      action_id: input.action_id,
      pack_ref: input.pack_ref,
      runner_refs: input.runner_refs,
      args: input.args,
      args_raw: input.args_raw,
      reason: input.reason,
      evidence: input.evidence,
      expected: input.expected,
      attestation_headers: attestation_headers,
      portal_origin: request_origin(conn)
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
      args_raw: args_raw,
      reason: args["reason"],
      # Optional, unenforced justification chain — persisted and rendered for
      # approvers/audit, never a policy/attestation input (so they stay out of
      # the signed facts + operation fingerprint below).
      evidence: args["evidence"],
      expected: args["expected"],
      wait: args["wait"] || "60s"
    }
  end

  defp invalid_action_arguments(issue) do
    path = if issue.code == "unknown_arg", do: [:args], else: [:args, issue.arg]

    ValidationError.payload("Action arguments do not match the trusted contract.",
      stage: :action_arguments,
      issues: [ValidationError.issue(path, issue.code)]
    )
  end

  defp target_contract_changed(conn, input) do
    :ok = log_rejected(conn, input, "target_contract_changed")

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

  defp not_allowed(conn, input) do
    :ok = log_rejected(conn, input, "not_allowed")
    {:error, error("not_allowed", "This key cannot dispatch actions.")}
  end

  defp log_rejected(conn, input, reason) do
    ValidationError.log_dispatch_rejected(conn, "run_action", reason,
      action_id: input.action_id,
      pack_ref: input.pack_ref
    )
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
