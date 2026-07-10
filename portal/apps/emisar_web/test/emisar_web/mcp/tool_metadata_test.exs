defmodule EmisarWeb.MCP.ToolMetadataTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.MCP.ToolMetadata

  test "adds OAuth requirements at both MCP metadata locations" do
    tool = ToolMetadata.auth_required(%{name: "linux.uptime"})

    assert tool.securitySchemes == [%{type: "oauth2", scopes: ["mcp"]}]
    assert tool._meta.securitySchemes == tool.securitySchemes
  end

  test "marks a low-risk action without side effects as read-only and idempotent" do
    annotations = ToolMetadata.action_annotations(%{risk: :low, side_effects: []})

    assert annotations.readOnlyHint == true
    assert annotations.idempotentHint == true
    assert annotations.destructiveHint == false
    assert annotations.openWorldHint == true
  end

  test "does not overstate mutating action safety" do
    medium = ToolMetadata.action_annotations(%{risk: :medium, side_effects: ["changes state"]})
    critical = ToolMetadata.action_annotations(%{risk: :critical, side_effects: []})

    assert medium.readOnlyHint == false
    assert medium.idempotentHint == false
    assert medium.destructiveHint == false
    assert critical.destructiveHint == true
  end

  # The risk-tier contract, exhaustively: low → read-only, medium →
  # non-read-only non-destructive, high/critical → destructive.
  test "maps every risk tier to the right annotation" do
    low = ToolMetadata.action_annotations(%{risk: :low, side_effects: []})
    medium = ToolMetadata.action_annotations(%{risk: :medium, side_effects: []})
    high = ToolMetadata.action_annotations(%{risk: :high, side_effects: []})
    critical = ToolMetadata.action_annotations(%{risk: :critical, side_effects: []})

    assert low.readOnlyHint == true
    assert low.destructiveHint == false

    assert medium.readOnlyHint == false
    assert medium.destructiveHint == false

    assert high.readOnlyHint == false
    assert high.destructiveHint == true

    assert critical.readOnlyHint == false
    assert critical.destructiveHint == true
  end

  test "read-only synthetic tools carry the full conservative annotation set" do
    assert ToolMetadata.read_only_annotations() == %{
             readOnlyHint: true,
             destructiveHint: false,
             openWorldHint: false,
             idempotentHint: true
           }
  end

  describe "group_annotations/1 — mixed runner variants" do
    test "read-only only when EVERY variant is read-only" do
      uniform = [%{risk: :low, side_effects: []}, %{risk: :low, side_effects: []}]

      annotations = ToolMetadata.group_annotations(uniform)
      assert annotations.readOnlyHint == true
      assert annotations.idempotentHint == true
      assert annotations.destructiveHint == false
    end

    test "a single non-read-only variant strips the read-only hint off the whole group" do
      mixed = [%{risk: :low, side_effects: []}, %{risk: :medium, side_effects: ["writes"]}]

      annotations = ToolMetadata.group_annotations(mixed)
      assert annotations.readOnlyHint == false
      assert annotations.idempotentHint == false
      assert annotations.destructiveHint == false
    end

    test "a single destructive variant marks the whole group destructive (never rides under a safe hint)" do
      mixed = [%{risk: :low, side_effects: []}, %{risk: :critical, side_effects: []}]

      annotations = ToolMetadata.group_annotations(mixed)
      assert annotations.destructiveHint == true
      assert annotations.readOnlyHint == false
    end
  end

  describe "worst_risk/1" do
    test "returns the highest risk any variant advertises" do
      assert ToolMetadata.worst_risk([%{risk: :low}, %{risk: :high}, %{risk: :medium}]) == :high
      assert ToolMetadata.worst_risk([%{risk: :low}, %{risk: :critical}]) == :critical
      assert ToolMetadata.worst_risk([%{risk: :low}]) == :low
    end
  end

  describe "group_title/1" do
    test "uses the shared human title when variants agree" do
      group = [
        %{action_id: "linux.restart_service", title: "Restart service"},
        %{action_id: "linux.restart_service", title: "Restart service"}
      ]

      assert ToolMetadata.group_title(group) == "Restart service"
    end

    test "picks deterministically (sorted) when titles diverge, independent of order" do
      forward = [
        %{action_id: "linux.restart_service", title: "Restart the service"},
        %{action_id: "linux.restart_service", title: "Restart service"}
      ]

      assert ToolMetadata.group_title(forward) == "Restart service"
      assert ToolMetadata.group_title(Enum.reverse(forward)) == "Restart service"
    end

    test "falls back to the action_id when no variant carries a title" do
      group = [
        %{action_id: "linux.restart_service", title: nil},
        %{action_id: "linux.restart_service", title: ""}
      ]

      assert ToolMetadata.group_title(group) == "linux.restart_service"
    end
  end
end
