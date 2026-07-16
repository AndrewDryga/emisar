defmodule Emisar.Catalog.TrustedManifestTest do
  use ExUnit.Case, async: true
  alias Emisar.Catalog.TrustedManifest

  test "rejects manifests whose complete compact pack cannot fit one MCP item" do
    actions =
      for index <- 1..80 do
        %{
          "id" => "test.action_#{index}",
          "title" => String.duplicate("t", 160),
          "summary" => String.duplicate("s", 512),
          "description" => "description",
          "kind" => "exec",
          "risk" => "low",
          "side_effects" => [],
          "args" => [],
          "examples" => [],
          "search_terms" => []
        }
      end

    assert {:error, :invalid_manifest} = TrustedManifest.from_catalog_actions(actions)
  end

  test "accepts an ordinary compact manifest" do
    action = %{
      "id" => "test.status",
      "title" => "Status",
      "summary" => "Show status.",
      "description" => "Show the current status.",
      "kind" => "exec",
      "risk" => "low",
      "side_effects" => [],
      "args" => [],
      "examples" => [],
      "search_terms" => []
    }

    assert {:ok, _manifest} = TrustedManifest.from_catalog_actions([action])
  end
end
