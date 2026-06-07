defmodule EmisarWeb.Mcp.ContentBlocks do
  @moduledoc """
  Render a Service.dispatch_tool result (or a Service.fetch_run payload)
  as MCP "content blocks" — the shape MCP clients render to the user.

  This is the canonical implementation; the stdio bridge used to ship
  its own copy of this in Go (renderRunBlocks). Now the bridge is
  pure transport and every MCP client gets identical formatting.

  Returns `{content_list, is_error_bool}`. The caller wraps these into
  a JSON-RPC `result` shape: `%{content: blocks, isError: is_error}`.
  """

  @doc """
  Synthetic tool descriptor for `wait_for_run`. Surfaced in
  tools/list so the LLM can park on a pending_approval run until the
  operator decides.
  """
  @spec wait_for_run_tool() :: map()
  def wait_for_run_tool do
    %{
      name: "wait_for_run",
      description:
        "Block on a previously-dispatched run until it reaches a terminal state " <>
          "(success, failed, denied, cancelled, etc.). Call this AUTOMATICALLY and immediately " <>
          "whenever a tool returns `status: \"pending_approval\"` — by default wait for the " <>
          "decision rather than asking the user whether to wait. The response carries a `run_id`; " <>
          "this tool polls the cloud for the operator's decision and the action's output. " <>
          "Times out after 5 minutes; if you hit the timeout while still pending, call " <>
          "wait_for_run again with the same run_id and keep waiting until it resolves.",
      inputSchema: %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["run_id"],
        "properties" => %{
          "run_id" => %{
            "type" => "string",
            "description" => "The run id returned by the tool that requested approval."
          },
          "timeout" => %{
            "type" => "string",
            "description" => "How long to block (e.g. \"60s\", \"3m\"). Max 5m. Defaults to 5m.",
            "pattern" => "^[0-9]+(ms|s|m)$"
          }
        }
      }
    }
  end

  @doc """
  Render the `runs` array from dispatch_tool as MCP content blocks.
  Returns `{blocks, any_error?}`. `multi` is true when there's more than
  one run so each block is prefixed with `[runner_name]`.
  """
  @spec from_runs([map()]) :: {[map()], boolean()}
  def from_runs(runs) when is_list(runs) do
    multi = length(runs) > 1

    {blocks, any_error} =
      Enum.reduce(runs, {[], false}, fn run, {acc, err_acc} ->
        {b, is_err} = render_run(run, multi)
        {acc ++ b, err_acc or is_err}
      end)

    blocks =
      if blocks == [],
        do: [text_block("(no output)")],
        else: blocks

    {blocks, any_error}
  end

  @doc "Render a single run payload (from fetch_run) as content blocks."
  @spec from_run(map()) :: {[map()], boolean()}
  def from_run(run) when is_map(run) do
    if waiting?(run) do
      {[
         text_block(
           "Run #{run_id(run)} is still #{inspect(run["status"] || run[:status])}. " <>
             "Call wait_for_run with the same run_id to keep waiting."
         )
       ], false}
    else
      render_run(run, false)
    end
  end

  @doc "Format a 4xx HTTP body as an error content block."
  @spec error_content(String.t(), String.t()) :: {[map()], true}
  def error_content(header, body) do
    {[text_block("#{header}: #{String.trim(body)}")], true}
  end

  # -- Per-run rendering ----------------------------------------------

  defp render_run(run, multi) do
    status = string_field(run, ["status"])

    cond do
      status == "pending_approval" -> render_pending_approval(run, multi)
      status in ["denied_by_policy", "denied"] -> render_denied(run, multi)
      (err = string_field(run, ["error"])) != "" -> render_validation_error(run, multi, err)
      # A run that's dispatched but not yet terminal (the wait window
      # elapsed before it finished). Surface the run_id so the LLM can
      # poll — otherwise render_terminal would emit a bare "status=sent"
      # with no handle and the round-trip dead-ends.
      status in ["pending", "sent", "running"] -> render_in_flight(run, multi)
      true -> render_terminal(run, multi)
    end
  end

  defp render_in_flight(run, multi) do
    hdr = header_prefix(run, multi)
    rid = run_id(run)
    status = string_field(run, ["status"])

    text =
      "#{hdr}Run dispatched (status=#{status}) but hasn't finished yet.\nrun_id: #{rid}\n\n" <>
        "Call `wait_for_run` with this run_id to block until it finishes and get the output."

    {[text_block(text)], false}
  end

  defp render_pending_approval(run, multi) do
    hdr = header_prefix(run, multi)
    rid = run_id(run)
    action = string_field(run, ["action_id"])
    why = policy_reason(run) || ""

    headline =
      "⏸ pending approval — " <>
        if(action != "", do: action, else: "this action") <>
        if(why != "", do: " (#{why})", else: "") <>
        "; a human approves it in the portal."

    text =
      "#{hdr}#{headline}\nrun_id: #{rid}\n\n" <>
        "This run is paused for human approval. By default, call `wait_for_run` with this " <>
        "run_id right now and keep waiting until the operator decides — do NOT stop to ask the " <>
        "user whether to wait. wait_for_run blocks up to 5 minutes per call; if it times out " <>
        "while still pending, call it again with the same run_id. Let the user know it's paused " <>
        "on them so they go approve it, but keep waiting. You'll get the action output on " <>
        "approve, or the denial reason on deny — report that outcome."

    {[text_block(text)], false}
  end

  defp render_denied(run, multi) do
    hdr = header_prefix(run, multi)
    msg = policy_reason(run) || string_field(run, ["reason"])
    {[text_block("#{hdr}Denied by policy: #{msg}")], true}
  end

  defp render_validation_error(run, multi, err) do
    hdr = header_prefix(run, multi)
    msg = string_field(run, ["message"])
    text = "#{hdr}Error: #{err}" <> if(msg != "", do: "\n#{msg}", else: "")
    {[text_block(text)], true}
  end

  defp render_terminal(run, multi) do
    status = string_field(run, ["status"])
    stdout = string_field(run, ["stdout"])
    stderr = string_field(run, ["stderr"])
    err_msg = string_field(run, ["error_message"])
    {exit_code, has_exit} = numeric_field(run, "exit_code")
    {duration, has_dur} = numeric_field(run, "duration_ms")

    headerline =
      [
        if(multi, do: "[#{string_field(run, ["runner"])}]", else: ""),
        if(status != "", do: "status=#{status}", else: ""),
        if(has_exit, do: "exit_code=#{trunc(exit_code)}", else: ""),
        if(has_dur, do: "duration=#{trunc(duration)}ms", else: "")
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")

    # An action that ran on a require_approval decision got here only
    # because a human approved it — lead with that so the LLM can tell the
    # user it cleared the gate and is on the record.
    approved? = policy_decision(run) == "require_approval"

    blocks =
      [
        if(approved?, do: text_block("✓ approved · audit event recorded")),
        if(headerline != "", do: text_block(headerline)),
        if(stdout != "", do: text_block(stdout)),
        if(stderr != "", do: text_block("stderr:\n" <> stderr)),
        if(err_msg != "", do: text_block("Error: " <> err_msg))
      ]
      |> Enum.reject(&is_nil/1)

    is_error = failure_status?(status) or (has_exit and trunc(exit_code) != 0)
    {blocks, is_error}
  end

  # -- Helpers --------------------------------------------------------

  defp text_block(text), do: %{type: "text", text: text}

  defp header_prefix(run, true) do
    case string_field(run, ["runner"]) do
      "" -> ""
      name -> "[#{name}] "
    end
  end

  defp header_prefix(_run, false), do: ""

  defp run_id(run), do: string_field(run, ["run_id", "id"])

  defp policy_reason(run) do
    case run["policy"] || run[:policy] do
      %{} = p -> p["reason"] || p[:reason]
      _ -> nil
    end
  end

  defp policy_decision(run) do
    case run["policy"] || run[:policy] do
      %{} = p -> p["decision"] || p[:decision]
      _ -> nil
    end
  end

  defp waiting?(run) do
    Map.has_key?(run, "waiting") or Map.has_key?(run, :waiting) or
      string_field(run, ["status"]) in ["pending_approval", "pending", "sent", "running"]
  end

  defp failure_status?(s),
    do:
      s in ~w(failed error validation_failed unknown_action cancelled timed_out denied denied_by_policy)

  defp string_field(map, keys) do
    Enum.find_value(keys, "", fn k ->
      v = Map.get(map, k) || Map.get(map, existing_atom(k))
      if is_binary(v) and v != "", do: v
    end) || ""
  end

  defp numeric_field(map, key) do
    case Map.get(map, key) || Map.get(map, existing_atom(key)) do
      n when is_number(n) -> {n * 1.0, true}
      _ -> {0.0, false}
    end
  end

  # IL-14: never grow the atom table from request data. The run payload
  # is built with atom keys, so the existing-atom lookup resolves them;
  # an unknown key just falls through to `nil` (no map hit) instead of
  # raising or minting a new atom.
  defp existing_atom(k) do
    String.to_existing_atom(k)
  rescue
    ArgumentError -> nil
  end
end
