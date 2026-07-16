defmodule EmisarWeb.MCP.ActionContractTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.MCP.{ActionContract, RawJSON}

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

  test "accepts every bundled example and declared default" do
    catalog =
      :emisar
      |> Application.app_dir("priv/packs/catalog.json")
      |> File.read!()
      |> Jason.decode!()

    for pack <- catalog["packs"], action <- pack["actions"] do
      for example <- action["examples"] || [] do
        result = ActionContract.validate(example["args"], action)
        assert result == :ok, "#{pack["id"]}.#{action["id"]}: #{inspect(result)}"
      end

      for spec <- action["args"] || [], Map.has_key?(spec, "default") do
        result =
          ActionContract.validate(%{spec["name"] => spec["default"]}, %{
            "args" => [spec]
          })

        assert result == :ok,
               "#{pack["id"]}.#{action["id"]}:#{spec["name"]}: #{inspect(result)}"
      end
    end
  end

  defp assert_issue(args, action, arg, code) do
    assert {:error, %{arg: ^arg, code: ^code}} = ActionContract.validate(args, action)
  end

  defp action(args), do: %{args_schema: %{"args" => args}}

  defp arg(name, type, opts \\ []) do
    %{"name" => name, "type" => type}
    |> maybe_put("required", opts[:required])
    |> maybe_put("validation", opts[:validation])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
