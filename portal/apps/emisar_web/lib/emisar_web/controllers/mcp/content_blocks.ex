defmodule EmisarWeb.MCP.ContentBlocks do
  @moduledoc """
  Render a Service.dispatch_tool result (or a Service.fetch_run payload)
  as MCP "content blocks" — the shape MCP clients render to the user.

  This is the canonical implementation; the stdio bridge used to ship
  its own copy of this in Go (renderRunBlocks). Now the bridge is
  pure transport and every MCP client gets identical formatting.

  Returns `{content_list, is_error_bool}`. The caller wraps these into
  a JSON-RPC `result` shape: `%{content: blocks, isError: is_error}`.
  """
  alias Emisar.Runs
  alias EmisarWeb.MCP.ToolMetadata

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
          "Times out after five minutes; if you hit the timeout while still pending, call " <>
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
            "description" => "How long to block (e.g. \"60s\", \"5m\"). Max 5m. Defaults to 5m.",
            "pattern" => "^[0-9]+(ms|s|m)$"
          }
        }
      },
      annotations: ToolMetadata.read_only_annotations()
    }
    |> ToolMetadata.auth_required()
  end

  @doc "Synthetic tool descriptor for `list_runbooks` (read-only)."
  @spec list_runbooks_tool() :: map()
  def list_runbooks_tool do
    %{
      name: "list_runbooks",
      description:
        "List this account's published runbooks. A runbook is a saved, ordered sequence of " <>
          "action steps (a playbook/checklist). Use this to discover them, then run one the " <>
          "governed way with `execute_runbook` (preferred — the cloud runs it end-to-end under " <>
          "policy/approval), or call `get_runbook` to inspect a runbook's steps first. Read-only.",
      inputSchema: %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{}
      },
      annotations: ToolMetadata.read_only_annotations()
    }
    |> ToolMetadata.auth_required()
  end

  @doc "Synthetic tool descriptor for `get_runbook` (read-only)."
  @spec get_runbook_tool() :: map()
  def get_runbook_tool do
    %{
      name: "get_runbook",
      description:
        "Read one published runbook's full definition: its ordered steps, each with an " <>
          "`action_id`, the `args` to pass, and the runner `target` (resolved to current runner " <>
          "names). To RUN it, prefer `execute_runbook` (the cloud runs it end-to-end under " <>
          "policy/approval and audits it as one execution); use this tool to inspect the steps " <>
          "first, or to run them yourself only if you need to diverge from the saved plan. " <>
          "Read-only.",
      inputSchema: %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["runbook"],
        "properties" => %{
          "runbook" => %{
            "type" => "string",
            "description" => "The runbook slug (from list_runbooks) or its id."
          }
        }
      },
      annotations: ToolMetadata.read_only_annotations()
    }
    |> ToolMetadata.auth_required()
  end

  @doc "Synthetic tool descriptor for `execute_runbook` (dispatches real actions)."
  @spec execute_runbook_tool() :: map()
  def execute_runbook_tool do
    %{
      name: "execute_runbook",
      description:
        "Execute a published runbook end-to-end on the cloud — the first-party, governed way to " <>
          "run one. Prefer this over dispatching each step yourself: the cloud expands the " <>
          "runbook into an audited execution, fans out the steps in waves to their target " <>
          "runners, and enforces the SAME policy, approval, runner-scope, and pack-trust gates " <>
          "as a normal action call. It returns a `runbook_execution_id` plus one summary per run " <>
          "dispatched in the first wave; later waves fire automatically as runs finish. A run " <>
          "that needs approval comes back `pending_approval` — call `wait_for_run` with its " <>
          "run_id. Only PUBLISHED runbooks can be executed (see list_runbooks). This runs real " <>
          "infrastructure actions.",
      inputSchema: %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["runbook", "reason"],
        "properties" => %{
          "runbook" => %{
            "type" => "string",
            "description" => "The published runbook's slug (from list_runbooks) or its id."
          },
          "reason" => %{
            "type" => "string",
            "description" =>
              "Why you are running this runbook — a short freeform sentence. Logged in the " <>
                "audit trail and carried onto every step's run. Required."
          }
        }
      },
      annotations: ToolMetadata.execute_runbook_annotations()
    }
    |> ToolMetadata.auth_required()
  end

  @doc "Synthetic tool descriptor for `create_runbook_draft` (writes a draft, never publishes)."
  @spec create_runbook_draft_tool() :: map()
  def create_runbook_draft_tool do
    %{
      name: "create_runbook_draft",
      description:
        "Save a proposed plan as a DRAFT runbook for an operator to review. This does NOT " <>
          "publish or run anything — the draft stays a draft until a human opens it in the " <>
          "portal and publishes it. Use this to hand the operator a reusable playbook you've " <>
          "worked out (an ordered list of action steps), not to execute work now. Give each " <>
          "step an `action_id`, its `args`, and a `runner_selector` (which host(s)/group it " <>
          "targets). Returns the draft's id/slug/version and a portal URL for review.",
      inputSchema: %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["title", "steps"],
        "properties" => %{
          "title" => %{
            "type" => "string",
            "description" => "Human-facing runbook title (1–80 chars)."
          },
          "slug" => %{
            "type" => "string",
            "description" =>
              "Optional URL-safe id (^[a-z][a-z0-9_-]{0,79}$). Omit to derive it from the title."
          },
          "description" => %{
            "type" => "string",
            "description" => "Optional one-line summary of what the runbook does."
          },
          "steps" => %{
            "type" => "array",
            "minItems" => 1,
            "description" => "Ordered steps the runbook runs.",
            "items" => %{
              "type" => "object",
              "required" => ["id", "action_id"],
              "properties" => %{
                "id" => %{
                  "type" => "string",
                  "description" => "Short unique step id (1–80 chars), e.g. \"restart\"."
                },
                "action_id" => %{
                  "type" => "string",
                  "description" => "The action to run, e.g. \"linux.uptime\"."
                },
                "args" => %{
                  "type" => "object",
                  "description" => "The action's arguments (same shape its tool takes)."
                },
                "runner_selector" => %{
                  "type" => "object",
                  "description" =>
                    "Which runner(s) the step targets — an object with a `group` key (list of " <>
                      "group names) or a `runner_id` key (list of runner ids). Required before " <>
                      "an operator can publish."
                }
              }
            }
          }
        }
      },
      annotations: ToolMetadata.draft_runbook_annotations()
    }
    |> ToolMetadata.auth_required()
  end

  @doc "Synthetic tool descriptor for `recent_runs` (read-only)."
  @spec recent_runs_tool() :: map()
  def recent_runs_tool do
    %{
      name: "recent_runs",
      description:
        "List the most recent action runs this agent (API key) dispatched, newest first — so you " <>
          "can recall what you already ran on a host and how it turned out (status, exit code) before " <>
          "re-running it. `scope: \"own\"` (default) returns only your own runs; " <>
          "`scope: \"account\"` widens to every agent in the account. Narrow with `runner` " <>
          "(a host name) and/or `action` (an action_id). Read-only.",
      inputSchema: %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{
          "limit" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => 100,
            "description" => "Max runs to return, newest first (default 20)."
          },
          "scope" => %{
            "type" => "string",
            "enum" => ["own", "account"],
            "description" =>
              "\"own\" (default) = only this key's runs; " <>
                "\"account\" = all agents in the account."
          },
          "runner" => %{
            "type" => "string",
            "description" =>
              "Only runs dispatched to this runner, by name (as shown in each summary's " <>
                "`runner`). Omit for all runners."
          },
          "action" => %{
            "type" => "string",
            "description" =>
              "Only runs of this action_id (e.g. \"linux.uptime\"). Omit for all actions."
          }
        }
      },
      annotations: ToolMetadata.read_only_annotations()
    }
    |> ToolMetadata.auth_required()
  end

  @doc "Render the `list_runbooks` summaries: a short intro plus the runbooks as JSON."
  @spec from_runbook_list([map()]) :: {[map()], boolean()}
  def from_runbook_list(summaries) when is_list(summaries) do
    intro =
      if summaries == [],
        do: "No published runbooks in this account yet.",
        else:
          "#{length(summaries)} published runbook(s). Run one with `execute_runbook` (the " <>
            "governed, audited way), or call `get_runbook` with a slug to inspect its steps first."

    {[text_block(intro), text_block(Jason.encode!(summaries, pretty: true))], false}
  end

  @doc "Render one `get_runbook` detail: how-to-execute guidance plus the definition as JSON."
  @spec from_runbook_detail(map()) :: {[map()], boolean()}
  def from_runbook_detail(detail) when is_map(detail) do
    guidance =
      "Runbook `#{detail.slug}` v#{detail.version}. To run it as-is, prefer `execute_runbook` " <>
        "with this slug — the cloud runs every step under policy/approval and audits it as one " <>
        "execution. Run the steps yourself only to diverge from the saved plan: for each step " <>
        "call its `action_id` with `args`, targeting the runners in `target.runners` " <>
        "(pass `runners: [...]`); an empty `target.runners` means none currently match the " <>
        "selector, so pick a runner from tools/list. Either way, honor each action's normal " <>
        "risk/approval (a high-risk step may return pending_approval; use wait_for_run as usual)."

    {[text_block(guidance), text_block(Jason.encode!(detail, pretty: true))], false}
  end

  @doc "Render an `execute_runbook` result: how-to-follow-up guidance plus the payload as JSON."
  @spec from_runbook_execution(map()) :: {[map()], boolean()}
  def from_runbook_execution(payload) when is_map(payload) do
    rb = payload.runbook
    dispatched = length(payload.dispatched)

    guidance =
      "Started a governed execution of runbook `#{rb.slug}` v#{rb.version} " <>
        "(execution #{payload.runbook_execution_id}). #{dispatched} run(s) dispatched in the " <>
        "first wave of #{payload.total_step_runs} total step-run(s); later waves fire " <>
        "automatically as runs finish. Each dispatched run carries its own status — one showing " <>
        "`pending_approval` is paused for an operator, so call `wait_for_run` with its run_id to " <>
        "block for the decision and output. A step denied by policy or a dispatch error halts " <>
        "the waves behind it; steps that were denied or halted do not appear as dispatched runs."

    {[text_block(guidance), text_block(Jason.encode!(payload, pretty: true))],
     payload.errors != []}
  end

  @doc "Render a `create_runbook_draft` result: review guidance plus the draft ids as JSON."
  @spec from_runbook_draft(map()) :: {[map()], boolean()}
  def from_runbook_draft(payload) when is_map(payload) do
    guidance =
      "Saved DRAFT runbook `#{payload.slug}` v#{payload.version} (id #{payload.runbook_id}). " <>
        "This did NOT publish or run it — it stays a draft for an operator to review. Point the " <>
        "user at #{payload.review_url} to open, finish, and publish it; only then can it be " <>
        "executed. Tell the user it's waiting on their review; do not treat the runbook as live."

    {[text_block(guidance), text_block(Jason.encode!(payload, pretty: true))], false}
  end

  @doc "Render `recent_runs`: a one-line intro plus the runs as compact JSON, newest first."
  @spec from_recent_runs([map()]) :: {[map()], boolean()}
  def from_recent_runs(runs) when is_list(runs) do
    intro =
      if runs == [],
        do: "No matching runs yet.",
        else: "#{length(runs)} recent run(s), newest first."

    {[text_block(intro), text_block(Jason.encode!(runs, pretty: true))], false}
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
        "user whether to wait. wait_for_run blocks up to five minutes per call; if it times out " <>
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
        if(output_truncated?(run),
          do: text_block("Output preview is truncated; do not treat it as complete evidence.")
        ),
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
      %{} = payload -> payload["reason"] || payload[:reason]
      _ -> nil
    end
  end

  defp policy_decision(run) do
    case run["policy"] || run[:policy] do
      %{} = payload -> payload["decision"] || payload[:decision]
      _ -> nil
    end
  end

  defp waiting?(run) do
    Map.has_key?(run, "waiting") or Map.has_key?(run, :waiting) or
      string_field(run, ["status"]) in ["pending_approval", "pending", "sent", "running"]
  end

  # is_error for a terminal run = any terminal NON-success status. The enum set
  # is derived from ActionRun (so a newly-added status like `:refused` — a runner
  # trust refusal — can't silently render as success), plus `denied_by_policy`,
  # the synthetic status the MCP dispatch path emits for a policy deny (service.ex).
  @failure_status_strings Enum.map(Runs.ActionRun.failure_statuses(), &Atom.to_string/1) ++
                            ["denied_by_policy"]

  defp failure_status?(s), do: s in @failure_status_strings

  defp string_field(map, keys) do
    Enum.find_value(keys, "", fn k ->
      v = Map.get(map, k) || Map.get(map, existing_atom(k))

      cond do
        is_binary(v) and v != "" -> v
        # An Ecto.Enum value (e.g. the run status :sent) arrives as an atom on
        # the pre-JSON RPC render path; normalize it at the edge so the string
        # comparisons in render/2 (status in ["sent", …]) see it.
        is_atom(v) and v not in [nil, false] -> to_string(v)
        true -> nil
      end
    end) || ""
  end

  defp numeric_field(map, key) do
    case Map.get(map, key) || Map.get(map, existing_atom(key)) do
      n when is_number(n) -> {n * 1.0, true}
      _ -> {0.0, false}
    end
  end

  defp output_truncated?(run) do
    Enum.any?(["stdout_truncated", "stderr_truncated", "output_events_truncated"], fn key ->
      Map.get(run, key) == true or Map.get(run, existing_atom(key)) == true
    end)
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
