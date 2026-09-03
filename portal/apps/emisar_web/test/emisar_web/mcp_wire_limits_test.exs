defmodule EmisarWeb.MCPWireLimitsTest do
  @moduledoc """
  Pins the limits the portal shares with its Go peers.

  Each one is a single contract with two implementations: the runner or the
  bridge ENFORCES the number and the portal accepts, advertises, or answers
  within it. Both sides spell it themselves, so without a test that reads both
  a change on one side leaves the other's gate green — and every surface here
  freezes at 1.0.

  Where the portal exposes the value, this reads the value. Where it only has a
  module attribute with no accessor, it reads the declaration out of the source
  the same way it reads Go's, so the pin needs no production change.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Runbooks
  alias EmisarWeb.CachedBodyReader
  alias EmisarWeb.MCP.{ResponseBudget, ToolSchema}

  @repo_root Path.expand("../../../../..", __DIR__)

  test "the MCP request-body boundary is the bridge's frame ceiling" do
    limit = go_constant!("mcp/main.go", "maxFrameBytes")

    at_limit = build_conn(:post, "/api/mcp/rpc", String.duplicate("x", limit))
    assert {:ok, _body, cached} = CachedBodyReader.read_body(at_limit, [])
    assert byte_size(cached.assigns.raw_body) == limit

    over_limit = build_conn(:post, "/api/mcp/rpc", String.duplicate("x", limit + 1))
    assert {:more, _partial, refused} = CachedBodyReader.read_body(over_limit, [])
    refute Map.has_key?(refused.assigns, :raw_body)
  end

  test "the MCP response frame ceiling is the bridge's response ceiling" do
    assert ResponseBudget.max_frame_bytes() == go_constant!("mcp/main.go", "maxResponseBytes")
  end

  test "the action-args ceiling advertised to the model is the runner's decode ceiling" do
    advertised = Runbooks.definition_limit!(:max_action_args_bytes)

    assert advertised == go_constant!("runner/internal/cloud/protocol.go", "maxActionArgsBytes")
    assert ToolSchema.action_args_schema(%{})["x-emisar-maxEncodedBytes"] == advertised

    # Any remaining portal copy must agree; an empty result means the copies are
    # gone, which is the state this is pushing toward.
    assert Enum.uniq(portal_attributes("max_action_args_bytes")) in [[], [advertised]]
  end

  test "the structured output the portal accepts is the runner's emit ceiling" do
    emitted = go_constant!("runner/internal/outputschema/outputschema.go", "MaxResultBytes")
    accepted = portal_attributes("max_structured_output_bytes")

    assert accepted != []
    assert Enum.uniq(accepted) == [emitted]
  end

  test "the runner's wire golden and the portal socket agree on the protocol" do
    golden = read_json!("runner/internal/cloud/testdata/wire_golden.json")
    socket = read_source!("portal/apps/emisar_web/lib/emisar_web/runner_socket.ex")
    versions = golden["frames"] |> Map.values() |> Enum.map(& &1["protocol_version"])

    assert Enum.uniq(versions) == [golden["protocol_version"]]
    assert attribute!(socket, "protocol_version") == golden["protocol_version"]

    # The golden pins both directions in one map and does not label them, so the
    # portal→runner names are stated here; everything left is what the socket
    # must accept. A frame added on either side lands on this assertion.
    outbound = ~w(ack_result action_result_typed cancel run_action shutdown)
    inbound = Map.keys(golden["frames"]) -- outbound

    assert Enum.sort(word_list!(socket, "known_runner_message_types")) == Enum.sort(inbound)
  end

  test "the runner_state frame and JSON depth ceilings match the runner's own" do
    connect =
      read_source!(
        "portal/apps/emisar_web/lib/emisar_web/controllers/runner_connect_controller.ex"
      )

    assert attribute!(connect, "runner_frame_max_bytes") ==
             go_constant!("runner/internal/cloud/state.go", "maxRunnerStateBytes")

    raw_json = read_source!("portal/apps/emisar/lib/emisar/raw_json.ex")

    assert attribute!(raw_json, "max_depth") ==
             go_constant!("runner/internal/cloud/protocol.go", "MaxDepth")
  end

  defp read_source!(path), do: @repo_root |> Path.join(path) |> File.read!()

  defp read_json!(path), do: path |> read_source!() |> Jason.decode!()

  # Matches a Go declaration in any of its shapes — `const Name = 1`, an aligned
  # entry inside a `const (...)` block, a `Name = 8 << 10` shift, and a
  # `Name: 64` struct field.
  defp go_constant!(path, name) do
    source = read_source!(path)

    pattern =
      Regex.compile!(
        "(?<![A-Za-z0-9_])#{Regex.escape(name)}\\s*[:=]\\s*(\\d+)(?:\\s*<<\\s*(\\d+))?(?![0-9])"
      )

    case Regex.run(pattern, source) do
      [_match, value] ->
        String.to_integer(value)

      [_match, value, shift] ->
        String.to_integer(value) * Integer.pow(2, String.to_integer(shift))

      nil ->
        flunk("#{path} no longer declares #{name}")
    end
  end

  defp attribute!(source, name) do
    case Regex.run(~r/^\s*@#{name}\s+([0-9_ *]+)$/m, source) do
      [_match, expression] -> product(expression)
      nil -> flunk("no @#{name} declaration found")
    end
  end

  defp word_list!(source, name) do
    [_match, words] = Regex.run(~r/^\s*@#{name}\s+~w\(([^)]*)\)/m, source)
    String.split(words)
  end

  defp portal_attributes(name) do
    @repo_root
    |> Path.join("portal/apps/*/lib/**/*.ex")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      ~r/^\s*@#{name}\s+([0-9_ *]+)$/m
      |> Regex.scan(File.read!(path))
      |> Enum.map(fn [_match, expression] -> product(expression) end)
    end)
  end

  defp product(expression) do
    expression
    |> String.split("*")
    |> Enum.map(&(&1 |> String.trim() |> String.replace("_", "") |> String.to_integer()))
    |> Enum.product()
  end
end
