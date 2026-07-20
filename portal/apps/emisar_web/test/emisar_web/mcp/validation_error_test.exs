defmodule EmisarWeb.MCP.ValidationErrorTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.MCP.ValidationError

  test "builds only normalized bounded validation details with a derived kind" do
    details =
      ValidationError.details(
        stage: "attacker-stage",
        issues: [
          %{path: "$.secret[value]", code: "attacker-code"},
          ValidationError.issue([:args, "Port_Name"], :type)
        ]
      )

    assert details == %{
             schema_version: 1,
             stage: "arguments",
             kind: "schema",
             issues: [
               %{path: "$", code: "schema"},
               %{path: "$.args.Port_Name", code: "type"}
             ]
           }
  end

  test "derives the published kind from the first rendered issue's code" do
    for {code, kind} <- [
          {:required, "missing"},
          {:unknown_arg, "unknown"},
          {:format, "format"},
          {:min, "range"},
          {:max_length, "size"},
          {:allowed, "enum"},
          {:conflict, "conflict"}
        ] do
      details = ValidationError.details(issues: [ValidationError.issue([:field], code)])
      assert details.kind == kind
    end
  end

  test "accepts semantic versions and drops arbitrary labels" do
    assert ValidationError.safe_version(" 1.2.3-rc.1+build.4 ") == "1.2.3-rc.1+build.4"
    assert ValidationError.safe_version("sk_live_secret") == nil
    assert ValidationError.safe_version(String.duplicate("1", 100)) == nil
  end
end
