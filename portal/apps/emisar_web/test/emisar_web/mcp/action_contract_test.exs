defmodule EmisarWeb.MCP.ActionContractTest do
  use ExUnit.Case, async: true
  alias Emisar.{ActionContract, JSONNumber}
  alias EmisarWeb.MCP.RawJSON

  test "accepts exact numeric tokens and every supported portable type" do
    action =
      action([
        arg("name", "string", required: true),
        arg("count", "integer"),
        arg("ratio", "number"),
        arg("force", "boolean"),
        arg("timeout", "duration"),
        arg("path", "path"),
        arg("tags", "string_array"),
        arg("ports", "integer_array")
      ])

    {:ok, args} =
      RawJSON.decode_object(
        ~s({"name":"db","count":1e3,"ratio":0.1234567890123456789,"force":true,"timeout":"1h30m","path":"/var/log/app.log","tags":["a","b"],"ports":[80,"443"]})
      )

    assert :ok = ActionContract.validate(args, action)
  end

  test "rejects unknown, missing, mistyped, and out-of-range arguments" do
    action =
      action([
        arg("count", "integer",
          required: true,
          validation: %{"min" => 1, "max" => 4}
        ),
        arg("mode", "string", validation: %{"enum" => ["safe"], "pattern" => "^[a-z]+$"})
      ])

    assert_issue(%{"extra" => true}, action, "extra", "unknown_arg")
    assert_issue(%{}, action, "count", "required")
    assert_issue(%{"count" => "1.5"}, action, "count", "type")
    assert_issue(%{"count" => 5}, action, "count", "max")
    assert_issue(%{"count" => 1, "mode" => "unsafe"}, action, "mode", "enum")
  end

  test "matches exact runner number membership and bounds" do
    exact =
      action([
        arg("ratio", "number", validation: %{"enum" => [1.25], "max" => 1.25}),
        arg("large", "integer", validation: %{"allowed" => [9_007_199_254_740_993]}),
        arg("tiny", "number", validation: %{"min" => 0})
      ])

    assert :ok =
             validate_json(
               ~s({"ratio":1.250,"large":9007199254740993,"tiny":1e-400}),
               exact
             )

    assert_issue_json(
      ~s({"ratio":1.2500000000000001,"large":9007199254740993,"tiny":1e-400}),
      exact,
      "ratio",
      "enum"
    )

    assert_issue_json(
      ~s({"ratio":1.25,"large":9007199254740992,"tiny":1e-400}),
      exact,
      "large",
      "allowed"
    )

    assert_issue_json(
      ~s({"ratio":1.25,"large":9007199254740993,"tiny":-1e-400}),
      exact,
      "tiny",
      "min"
    )

    zero = action([arg("value", "number", validation: %{"enum" => [0]})])
    assert :ok = validate_json(~s({"value":-0}), zero)
    assert_issue_json(~s({"value":1e-400}), zero, "value", "enum")

    decimal_max = action([arg("value", "number", validation: %{"max" => 1.25})])
    assert_issue_json(~s({"value":1.2500000000000001}), decimal_max, "value", "max")

    integer_max =
      action([arg("value", "integer", validation: %{"max" => 9_007_199_254_740_992.0})])

    assert_issue_json(~s({"value":9007199254740993}), integer_max, "value", "max")
  end

  test "matches runner float64 admissibility at the finite boundary" do
    action = action([arg("value", "number")])

    for raw <- ["2e-324", "3e-324", "1.797693134862315807e308"] do
      assert :ok = validate_json(~s({"value":#{raw}}), action)
    end

    for raw <- ["1.797693134862315808e308", "1e309"] do
      assert_issue_json(~s({"value":#{raw}}), action, "value", "type")
    end
  end

  test "applies byte, array element, duration, and portable path limits" do
    action =
      action([
        arg("labels", "string_array", validation: %{"max_items" => 2, "max_length" => 3}),
        arg("delay", "duration",
          validation: %{"min_duration" => "1s", "max_duration" => "1h0m0s"}
        ),
        arg("file", "path", validation: %{"allowed_prefixes" => ["/var/log"]})
      ])

    assert_issue(%{"labels" => ["a", "b", "c"]}, action, "labels", "max_items")
    assert_issue(%{"labels" => ["abcd"]}, action, "labels", "max_length")
    assert_issue(%{"delay" => "500ms"}, action, "delay", "min_duration")
    assert_issue(%{"delay" => "2h"}, action, "delay", "max_duration")
    assert_issue(%{"file" => "relative.log"}, action, "file", "path")
    assert :ok = ActionContract.validate(%{"delay" => "1h", "file" => "/var/log/app"}, action)
  end

  test "defers patterns to the runner and matches Go duration range semantics" do
    action =
      action([
        arg("name", "string", validation: %{"pattern" => "^[a-z]+$"}),
        arg("delay", "duration", validation: %{"min_duration" => "1ns"})
      ])

    assert :ok = ActionContract.validate(%{"name" => "safe\n"}, action)
    assert_issue(%{"delay" => "0.6ns0.6ns"}, action, "delay", "min_duration")
    assert_issue(%{"delay" => "2562048h"}, action, "delay", "type")
    assert :ok = ActionContract.validate(%{"delay" => "0"}, action([arg("delay", "duration")]))

    assert :ok =
             ActionContract.validate(
               %{"delay" => "1.0000000000000000000000000000000000000001ns"},
               action([arg("delay", "duration", validation: %{"min_duration" => "1ns"})])
             )

    tiny_fraction = "1." <> String.duplicate("0", 400) <> "1ns"

    assert :ok =
             ActionContract.validate(
               %{"delay" => tiny_fraction},
               action([arg("delay", "duration", validation: %{"min_duration" => "1ns"})])
             )

    assert :ok =
             ActionContract.validate(
               %{"delay" => "2562047h47m16.854775807s"},
               action([arg("delay", "duration")])
             )

    assert :ok =
             ActionContract.validate(
               %{"delay" => "-2562047h47m16.854775808s"},
               action([arg("delay", "duration")])
             )
  end

  test "renders declared defaults as browser form values" do
    action =
      action([
        arg("path", "string", default: "/var/log"),
        arg("count", "integer", default: 5),
        arg("ratio", "number", default: 0.5),
        arg("delay", "duration", default: "5m"),
        arg("force", "boolean", default: true),
        arg("quiet", "boolean", default: false),
        arg("verbose", "boolean"),
        arg("tags", "string_array", default: ["a", "b"]),
        arg("ports", "integer_array", default: []),
        arg("name", "string")
      ])

    assert ActionContract.form_values(action) == %{
             "path" => "/var/log",
             "count" => "5",
             "ratio" => "0.5",
             "delay" => "5m",
             "force" => "true",
             "quiet" => "false",
             "verbose" => "false",
             "tags" => "a, b",
             "ports" => "",
             "name" => ""
           }
  end

  test "casts every portable form type into JSON-encodable arguments" do
    action =
      action([
        arg("name", "string", required: true),
        arg("file", "path"),
        arg("count", "integer"),
        arg("ratio", "number"),
        arg("force", "boolean"),
        arg("timeout", "duration"),
        arg("tags", "string_array"),
        arg("ports", "integer_array"),
        arg("note", "string")
      ])

    raw = %{
      "name" => "db",
      "file" => "/var/log/app.log",
      "count" => " 42 ",
      "ratio" => " 0.1234567890123456789 ",
      "force" => "on",
      "timeout" => "1h30m",
      "tags" => "a, ,b ,",
      "ports" => "80, 443",
      "note" => ""
    }

    assert {:ok, args} = ActionContract.cast_form(raw, action)

    assert args == %{
             "name" => "db",
             "file" => "/var/log/app.log",
             "count" => 42,
             "ratio" => %JSONNumber{raw: "0.1234567890123456789"},
             "force" => true,
             "timeout" => "1h30m",
             "tags" => ["a", "b"],
             "ports" => [80, 443]
           }

    assert Jason.encode!(args) =~ ~s("ratio":0.1234567890123456789)
    assert ActionContract.validate(args, action) == :ok
  end

  test "fills unsubmitted arguments from the rendered defaults" do
    action =
      action([
        arg("mode", "string", required: true, default: "safe"),
        arg("delay", "duration", default: "5m"),
        arg("file", "path")
      ])

    assert ActionContract.cast_form(%{}, action) == {:ok, %{"mode" => "safe", "delay" => "5m"}}

    assert {:error, [%{arg: "mode", code: "required", path: ["mode"]}]} =
             ActionContract.cast_form(%{"mode" => ""}, action)
  end

  test "applies the portable bounds to cast form values" do
    action =
      action([
        arg("delay", "duration", validation: %{"max_duration" => "1h"}),
        arg("file", "path", validation: %{"allowed_prefixes" => ["/var/log"]}),
        arg("labels", "string_array", validation: %{"max_items" => 1, "max_length" => 3}),
        arg("mode", "string", validation: %{"enum" => ["safe"]})
      ])

    assert {:error, [%{arg: "delay", code: "max_duration"}]} =
             ActionContract.cast_form(%{"delay" => "2h"}, action)

    assert {:error, [%{arg: "file", code: "path"}]} =
             ActionContract.cast_form(%{"file" => "relative.log"}, action)

    assert {:error, [%{arg: "labels", code: "max_items"}]} =
             ActionContract.cast_form(%{"labels" => "a, b"}, action)

    assert {:error, [%{arg: "labels", code: "max_length", path: ["labels", 0]}]} =
             ActionContract.cast_form(%{"labels" => "abcd"}, action)

    assert {:error, [%{arg: "mode", code: "enum"}]} =
             ActionContract.cast_form(%{"mode" => "unsafe"}, action)
  end

  test "reports every failing form argument in schema order with its path" do
    action =
      action([
        arg("pid", "integer", required: true),
        arg("force", "boolean"),
        arg("ratio", "number"),
        arg("ports", "integer_array"),
        arg("labels", "string_array", validation: %{"max_items" => 1})
      ])

    raw = %{
      "pid" => "",
      "force" => "maybe",
      "ratio" => "1e309",
      "ports" => "80, http",
      "labels" => "a, b"
    }

    assert {:error, issues} = ActionContract.cast_form(raw, action)

    assert Enum.map(issues, &{&1.arg, &1.code, &1.path}) == [
             {"pid", "required", ["pid"]},
             {"force", "type", ["force"]},
             {"ratio", "type", ["ratio"]},
             {"ports", "type", ["ports", 1]},
             {"labels", "max_items", ["labels"]}
           ]
  end

  test "rejects submitted arguments the contract does not declare" do
    action = action([arg("path", "string")])

    assert {:error, issues} = ActionContract.cast_form(%{"zeta" => "1", "alpha" => "2"}, action)

    assert Enum.map(issues, &{&1.arg, &1.code}) == [
             {"alpha", "unknown_arg"},
             {"zeta", "unknown_arg"}
           ]

    assert ActionContract.cast_form("not an object", action) ==
             {:error, [%{arg: "args", code: "type", message: "expected object", path: ["args"]}]}
  end

  test "accepts every bundled example and declared default" do
    catalog =
      :emisar
      |> Application.app_dir("priv/packs/catalog.json")
      |> File.read!()
      |> Jason.decode!()

    for pack <- catalog["packs"], action <- pack["actions"] do
      contract = %{args_schema: %{"args" => action["args"] || []}}

      for example <- action["examples"] || [] do
        result = ActionContract.validate(example["args"], contract)
        assert result == :ok, "#{pack["id"]}.#{action["id"]}: #{inspect(result)}"
      end

      for spec <- action["args"] || [], Map.has_key?(spec, "default") do
        default_contract = %{args_schema: %{"args" => [spec]}}
        result = ActionContract.validate(%{spec["name"] => spec["default"]}, default_contract)

        assert result == :ok,
               "#{pack["id"]}.#{action["id"]}:#{spec["name"]}: #{inspect(result)}"

        # The rendered default is what an operator submits untouched, so it has
        # to survive the browser round trip and land back on the contract.
        form = ActionContract.form_values(default_contract)
        cast = ActionContract.cast_form(form, default_contract)

        assert {:ok, cast_args} = cast,
               "#{pack["id"]}.#{action["id"]}:#{spec["name"]}: #{inspect(cast)}"

        assert ActionContract.validate(cast_args, default_contract) == :ok
      end
    end
  end

  defp assert_issue(args, action, arg, code) do
    assert {:error, %{arg: ^arg, code: ^code}} = ActionContract.validate(args, action)
  end

  defp assert_issue_json(json, action, arg, code) do
    assert {:error, %{arg: ^arg, code: ^code}} = validate_json(json, action)
  end

  defp validate_json(json, action) do
    {:ok, args} = RawJSON.decode_object(json)
    ActionContract.validate(args, action)
  end

  defp action(args), do: %{args_schema: %{"args" => args}}

  defp arg(name, type, opts \\ []) do
    %{"name" => name, "type" => type}
    |> maybe_put("required", opts[:required])
    |> maybe_put("validation", opts[:validation])
    |> maybe_put("default", opts[:default])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
