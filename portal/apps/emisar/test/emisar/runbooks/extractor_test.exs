defmodule Emisar.Runbooks.ExtractorTest do
  use ExUnit.Case, async: true
  alias Emisar.Runbooks.{Definition, Extractor}

  describe "extract_outputs/2" do
    test "resolves escaped object keys and array indexes with JSON Pointer" do
      outputs = [
        output("value", "structured_output", "json_pointer", "/a~1b/~0key/1")
      ]

      materialized = %{
        "structured_output" => %{"a/b" => %{"~key" => ["first", %{"ok" => true}]}}
      }

      assert {:ok, result} = Extractor.extract_outputs(outputs, materialized)
      assert result.raw == %{"value" => %{"ok" => true}}
      assert result.public == result.raw
    end

    test "parses bounded JSON text before applying a pointer" do
      outputs = [output("state", "stdout", "json_pointer", "/replica/state")]
      materialized = %{"stdout" => ~s({"replica":{"state":"streaming"}})}

      assert {:ok, result} = Extractor.extract_outputs(outputs, materialized)
      assert result.raw == %{"state" => "streaming"}
    end

    test "rejects malformed JSON text and unresolved pointers" do
      json_output = [output("state", "stdout", "json_pointer", "/state")]

      assert {:error, "extraction_failed", message, _evidence} =
               Extractor.extract_outputs(json_output, %{"stdout" => "not-json"})

      assert message == "Extractor source is not valid JSON."

      assert {:error, "extraction_failed", message, _evidence} =
               Extractor.extract_outputs(json_output, %{"stdout" => "{}"})

      assert message == "JSON Pointer does not resolve."
    end

    test "extracts contains, literal grep, and regex captures" do
      outputs = [
        output("has_ready", "stdout", "contains", "ready=true"),
        output("warnings", "stdout", "grep", "WARN"),
        regex_output("host", "stdout", "host=(?<host>[a-z0-9.-]+)", "host"),
        regex_output("port", "stdout", "port=([0-9]+)", "1"),
        regex_output("full", "stdout", "ready=true", "0")
      ]

      materialized = %{
        "stdout" => "INFO host=db-1.internal\nWARN lag=2\nport=5432\nready=true\nWARN lag=1"
      }

      assert {:ok, result} = Extractor.extract_outputs(outputs, materialized)

      assert result.raw == %{
               "full" => "ready=true",
               "has_ready" => true,
               "host" => "db-1.internal",
               "port" => "5432",
               "warnings" => ["WARN lag=2", "WARN lag=1"]
             }
    end

    test "fails when grep would exceed the matching-line cap" do
      line_count = Definition.limit!(:max_grep_lines) + 1
      text = Enum.map_join(1..line_count, "\n", &"MATCH #{&1}")
      outputs = [output("matches", "stdout", "grep", "MATCH")]

      assert {:error, "extraction_failed", message, _evidence} =
               Extractor.extract_outputs(outputs, %{"stdout" => text})

      assert message == "Grep output exceeds the matching-line limit."
    end

    test "fails when an extracted value exceeds its encoded byte cap" do
      value = String.duplicate("x", Definition.limit!(:max_extracted_value_bytes))
      outputs = [output("value", "structured_output", "json_pointer", "/value")]

      assert {:error, "extraction_failed", message, _evidence} =
               Extractor.extract_outputs(outputs, %{"structured_output" => %{"value" => value}})

      assert message == "Extracted value exceeds the encoded byte limit."
    end
  end

  describe "evaluate_materialized/3" do
    test "evaluates every supported typed condition with all-of semantics" do
      outputs = [
        output("same", "structured_output", "json_pointer", "/same"),
        output("different", "structured_output", "json_pointer", "/different"),
        output("number", "structured_output", "json_pointer", "/number"),
        output("text", "structured_output", "json_pointer", "/text"),
        output("members", "structured_output", "json_pointer", "/members")
      ]

      conditions = [
        condition("same", "equals", true),
        condition("different", "not_equals", "expected"),
        condition("number", "greater_than", 4),
        condition("number", "greater_than_or_equal", 5),
        condition("number", "less_than", 6),
        condition("number", "less_than_or_equal", 5),
        condition("text", "contains", "ready"),
        condition("members", "contains", "db-2"),
        condition("text", "one_of", ["not-ready", "replica ready"]),
        condition("text", "matches", "^replica [a-z]+$")
      ]

      materialized = %{
        "structured_output" => %{
          "same" => true,
          "different" => "actual",
          "number" => 5,
          "text" => "replica ready",
          "members" => ["db-1", "db-2"]
        }
      }

      assert {:ok, result} = Extractor.evaluate_materialized(outputs, conditions, materialized)
      assert result.conditions_met?
      assert Enum.all?(result.evidence, &(&1["status"] in ["extracted", "passed"]))
    end

    test "retains a normal condition mismatch as bounded failed evidence" do
      outputs = [output("state", "structured_output", "json_pointer", "/state")]
      conditions = [condition("state", "equals", "streaming")]
      materialized = %{"structured_output" => %{"state" => "catching_up"}}

      assert {:ok, result} = Extractor.evaluate_materialized(outputs, conditions, materialized)
      refute result.conditions_met?

      assert List.last(result.evidence) == %{
               "actual" => "catching_up",
               "expected" => "streaming",
               "kind" => "condition",
               "operator" => "equals",
               "output" => "state",
               "status" => "failed"
             }
    end

    test "fails closed when condition types cannot be evaluated" do
      outputs = [output("state", "structured_output", "json_pointer", "/state")]
      conditions = [condition("state", "greater_than", 1)]
      materialized = %{"structured_output" => %{"state" => "unknown"}}

      assert {:error, "extraction_failed", message, [_extraction, evidence]} =
               Extractor.evaluate_materialized(outputs, conditions, materialized)

      assert message == "A success condition could not be evaluated safely."
      assert evidence["status"] == "error"
    end

    test "redacts sensitive output and condition evidence while retaining raw binding data" do
      outputs = [
        output("token", "structured_output", "json_pointer", "/token", sensitive: true)
      ]

      conditions = [condition("token", "equals", "secret-token")]
      materialized = %{"structured_output" => %{"token" => "secret-token"}}

      assert {:ok, result} = Extractor.evaluate_materialized(outputs, conditions, materialized)
      assert result.raw == %{"token" => "secret-token"}
      assert result.public == %{"token" => "[REDACTED]"}
      refute inspect(result.evidence) =~ "secret-token"

      assert Enum.all?(
               result.evidence,
               &(&1["value"] == "[REDACTED]" or &1["actual"] == "[REDACTED]")
             )
    end

    test "treats an invalid runtime regex as an evaluation error, not a mismatch" do
      outputs = [output("state", "structured_output", "json_pointer", "/state")]
      conditions = [condition("state", "matches", "[")]
      materialized = %{"structured_output" => %{"state" => "ready"}}

      assert {:error, "extraction_failed", _message, [_extraction, evidence]} =
               Extractor.evaluate_materialized(outputs, conditions, materialized)

      assert evidence["status"] == "error"
    end
  end

  defp output(id, source, type, expression, opts \\ []) do
    %{
      "id" => id,
      "source" => source,
      "sensitive" => Keyword.get(opts, :sensitive, false),
      "extract" => %{"type" => type, "expression" => expression}
    }
  end

  defp regex_output(id, source, expression, capture) do
    %{
      "id" => id,
      "source" => source,
      "sensitive" => false,
      "extract" => %{"type" => "regex", "expression" => expression, "capture" => capture}
    }
  end

  defp condition(output, operator, value),
    do: %{"output" => output, "operator" => operator, "value" => value}
end
