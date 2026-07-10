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
end
