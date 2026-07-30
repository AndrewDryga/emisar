defmodule Emisar.Runbooks.Extractor do
  @moduledoc """
  Bounded extraction and success evaluation for one successful action attempt.

  Patterns are data, never commands. Text comes from Runs' bounded persisted
  output seam; sensitive extracted values are returned separately from the
  permanently redacted evidence projection.
  """

  alias Emisar.Runbooks.Definition

  @redacted "[REDACTED]"
  @regex_match_limit 10_000

  @type result ::
          {:ok,
           %{
             raw: map(),
             public: map(),
             evidence: [map()],
             conditions_met?: boolean()
           }}
          | {:error, String.t(), String.t(), [map()]}

  @doc "Materialize, extract, and evaluate one terminal successful action run."
  @spec evaluate(Emisar.Runs.ActionRun.t(), [map()], [map()]) :: result()
  def evaluate(run, output_plan, success_plan)
      when is_list(output_plan) and is_list(success_plan) do
    sources = output_plan |> Enum.map(& &1["source"]) |> Enum.uniq()

    with {:ok, materialized} <-
           Emisar.Runs.materialize_runbook_output(
             run.id,
             run.account_id,
             sources,
             Definition.limit!(:max_extractor_text_bytes)
           ),
         {:ok, result} <- evaluate_materialized(output_plan, success_plan, materialized) do
      {:ok, result}
    else
      {:error, reason} when is_atom(reason) ->
        message = output_error_message(reason)
        code = output_error_code(reason)
        evidence = Enum.map(output_plan, &output_evidence(&1, nil, "error", message))
        {:error, code, message, evidence}

      {:error, code, message, evidence} ->
        {:error, code, message, evidence}
    end
  end

  @doc "Pure bounded output evaluation used by the scheduler's focused tests."
  def evaluate_materialized(output_plan, success_plan, materialized)
      when is_list(output_plan) and is_list(success_plan) and is_map(materialized) do
    with {:ok, extracted} <- extract_outputs(output_plan, materialized) do
      case evaluate_conditions(success_plan, extracted.raw, extracted.sensitive) do
        {:ok, conditions} ->
          {:ok,
           %{
             raw: extracted.raw,
             public: extracted.public,
             evidence: extracted.evidence ++ conditions.evidence,
             conditions_met?: conditions.met?
           }}

        {:error, code, message, evidence} ->
          {:error, code, message, extracted.evidence ++ evidence}
      end
    end
  end

  @doc "Pure bounded extractor used by focused tests and the scheduler."
  def extract_outputs(output_plan, materialized)
      when is_list(output_plan) and is_map(materialized) do
    output_plan
    |> Enum.reduce_while(
      {:ok, %{raw: %{}, public: %{}, sensitive: MapSet.new(), evidence: []}},
      fn
        declaration, {:ok, state} ->
          case extract_one(declaration, materialized) do
            {:ok, value} ->
              append_output(state, declaration, value)

            {:error, message} ->
              evidence = [
                output_evidence(declaration, nil, "error", message) | state.evidence
              ]

              {:halt, {:error, "extraction_failed", message, Enum.reverse(evidence)}}
          end
      end
    )
    |> case do
      {:ok, state} -> {:ok, %{state | evidence: Enum.reverse(state.evidence)}}
      {:error, _code, _message, _evidence} = error -> error
    end
  end

  defp append_output(state, declaration, value) do
    case Jason.encode(value) do
      {:ok, encoded} ->
        if byte_size(encoded) <= Definition.limit!(:max_extracted_value_bytes) do
          id = declaration["id"]
          sensitive? = declaration["sensitive"]
          public_value = if sensitive?, do: @redacted, else: value

          next = %{
            raw: Map.put(state.raw, id, value),
            public: Map.put(state.public, id, public_value),
            sensitive: maybe_put_sensitive(state.sensitive, id, sensitive?),
            evidence: [
              output_evidence(declaration, public_value, "extracted", nil) | state.evidence
            ]
          }

          {:cont, {:ok, next}}
        else
          extraction_too_large(state, declaration)
        end

      _invalid_or_large ->
        extraction_too_large(state, declaration)
    end
  end

  defp extraction_too_large(state, declaration) do
    message = "Extracted value exceeds the encoded byte limit."
    evidence = [output_evidence(declaration, nil, "error", message) | state.evidence]
    {:halt, {:error, "extraction_failed", message, Enum.reverse(evidence)}}
  end

  defp maybe_put_sensitive(names, id, true), do: MapSet.put(names, id)
  defp maybe_put_sensitive(names, _id, false), do: names

  defp extract_one(%{"source" => source, "extract" => extract}, materialized) do
    value = Map.get(materialized, source)

    case extract do
      %{"type" => "json_pointer", "expression" => expression} ->
        with {:ok, json} <- json_source(value) do
          json_pointer(json, expression)
        end

      %{"type" => "contains", "expression" => expression} when is_binary(value) ->
        {:ok, String.contains?(value, expression)}

      %{"type" => "grep", "expression" => expression} when is_binary(value) ->
        matches =
          value
          |> String.split("\n")
          |> Enum.filter(&String.contains?(&1, expression))
          |> Enum.take(Definition.limit!(:max_grep_lines) + 1)

        if length(matches) <= Definition.limit!(:max_grep_lines),
          do: {:ok, matches},
          else: {:error, "Grep output exceeds the matching-line limit."}

      %{"type" => "regex", "expression" => expression, "capture" => capture}
      when is_binary(value) ->
        regex_capture(value, expression, capture)

      _unsupported ->
        {:error, "Extractor source does not contain the required value type."}
    end
  end

  defp json_source(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, json} -> {:ok, json}
      {:error, _reason} -> {:error, "Extractor source is not valid JSON."}
    end
  end

  defp json_source(value), do: {:ok, value}

  defp json_pointer(value, ""), do: {:ok, value}

  defp json_pointer(value, "/" <> encoded_tokens) do
    encoded_tokens
    |> String.split("/")
    |> Enum.reduce_while({:ok, value}, fn encoded, {:ok, current} ->
      case decode_pointer_token(encoded) do
        {:ok, token} -> pointer_child(token, {:ok, current})
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp json_pointer(_value, _pointer), do: {:error, "JSON Pointer is invalid."}

  defp decode_pointer_token(token) do
    if Regex.match?(~r/~(?:[^01]|$)/, token) do
      {:error, "JSON Pointer is invalid."}
    else
      {:ok, token |> String.replace("~1", "/") |> String.replace("~0", "~")}
    end
  end

  defp pointer_child(token, {:ok, %{} = value}) do
    case Map.fetch(value, token) do
      {:ok, child} -> {:cont, {:ok, child}}
      :error -> {:halt, {:error, "JSON Pointer does not resolve."}}
    end
  end

  defp pointer_child(token, {:ok, value}) when is_list(value) do
    with {index, ""} <- Integer.parse(token),
         true <- index >= 0,
         {:ok, child} <- Enum.fetch(value, index) do
      {:cont, {:ok, child}}
    else
      _invalid -> {:halt, {:error, "JSON Pointer does not resolve."}}
    end
  end

  defp pointer_child(_token, {:ok, _value}),
    do: {:halt, {:error, "JSON Pointer does not resolve."}}

  defp regex_capture(value, expression, capture) do
    with {:ok, compiled} <- :re.compile(expression, [:unicode]),
         capture_spec <- regex_capture_spec(capture),
         {:match, [matched]} <-
           :re.run(value, compiled, [
             {:capture, [capture_spec], :binary},
             {:match_limit, @regex_match_limit},
             {:match_limit_recursion, @regex_match_limit}
           ]) do
      {:ok, matched}
    else
      :nomatch ->
        {:error, "Regex did not match."}

      {:match, [nil]} ->
        {:error, "Regex capture did not participate in the match."}

      {:error, :match_limit} ->
        {:error, "Regex evaluation exceeded its safety limit."}

      {:error, :match_limit_recursion} ->
        {:error, "Regex evaluation exceeded its safety limit."}

      {:error, _reason} ->
        {:error, "Regex pattern is invalid."}

      _invalid ->
        {:error, "Regex capture is invalid."}
    end
  end

  defp regex_capture_spec(capture) do
    case Integer.parse(capture) do
      {index, ""} -> index
      _named -> String.to_charlist(capture)
    end
  end

  defp evaluate_conditions(conditions, outputs, sensitive) do
    conditions
    |> Enum.reduce_while({:ok, []}, fn condition, {:ok, evidence} ->
      with {:ok, actual} <- Map.fetch(outputs, condition["output"]),
           {:ok, passed?} <-
             condition_result(actual, condition["operator"], condition["value"]) do
        sensitive? = MapSet.member?(sensitive, condition["output"])

        row = %{
          "kind" => "condition",
          "output" => condition["output"],
          "operator" => condition["operator"],
          "actual" => if(sensitive?, do: @redacted, else: actual),
          "expected" => if(sensitive?, do: @redacted, else: condition["value"]),
          "status" => if(passed?, do: "passed", else: "failed")
        }

        {:cont, {:ok, [row | evidence]}}
      else
        _invalid ->
          message = "A success condition could not be evaluated safely."

          row = %{
            "kind" => "condition",
            "output" => condition["output"],
            "operator" => condition["operator"],
            "actual" => nil,
            "expected" => nil,
            "status" => "error",
            "message" => message
          }

          {:halt, {:error, "extraction_failed", message, Enum.reverse([row | evidence])}}
      end
    end)
    |> case do
      {:ok, evidence} ->
        evidence = Enum.reverse(evidence)
        {:ok, %{met?: Enum.all?(evidence, &(&1["status"] == "passed")), evidence: evidence}}

      {:error, _code, _message, _evidence} = error ->
        error
    end
  end

  defp condition_result(actual, "equals", expected), do: {:ok, actual == expected}
  defp condition_result(actual, "not_equals", expected), do: {:ok, actual != expected}

  defp condition_result(actual, operator, expected)
       when operator in [
              "greater_than",
              "greater_than_or_equal",
              "less_than",
              "less_than_or_equal"
            ] and is_number(actual) and is_number(expected) do
    result =
      case operator do
        "greater_than" -> actual > expected
        "greater_than_or_equal" -> actual >= expected
        "less_than" -> actual < expected
        "less_than_or_equal" -> actual <= expected
      end

    {:ok, result}
  end

  defp condition_result(actual, "contains", expected)
       when is_binary(actual) and is_binary(expected),
       do: {:ok, String.contains?(actual, expected)}

  defp condition_result(actual, "contains", expected) when is_list(actual),
    do: {:ok, expected in actual}

  defp condition_result(actual, "one_of", expected) when is_list(expected),
    do: {:ok, actual in expected}

  defp condition_result(actual, "matches", expression)
       when is_binary(actual) and is_binary(expression) do
    with {:ok, compiled} <- :re.compile(expression, [:unicode]) do
      case :re.run(actual, compiled, [
             {:capture, :none},
             {:match_limit, @regex_match_limit},
             {:match_limit_recursion, @regex_match_limit}
           ]) do
        :match -> {:ok, true}
        :nomatch -> {:ok, false}
        {:error, _reason} -> {:error, :regex_limit}
      end
    end
  end

  defp condition_result(_actual, _operator, _expected), do: {:error, :incompatible_types}

  defp output_evidence(declaration, value, status, message) do
    %{
      "kind" => "extraction",
      "output" => declaration["id"],
      "source" => declaration["source"],
      "extractor" => declaration["extract"]["type"],
      "value" => value,
      "status" => status,
      "message" => message
    }
  end

  defp output_error_message(:output_incomplete),
    do: "Relevant action output is incomplete or truncated."

  defp output_error_message(:output_invalid), do: "Relevant action output is invalid UTF-8."
  defp output_error_message(:output_too_large), do: "Relevant action output exceeds the limit."
  defp output_error_message(:not_found), do: "Action output is no longer available."
  defp output_error_message(_reason), do: "Action output is unavailable."

  defp output_error_code(reason) when reason in [:output_incomplete, :not_found],
    do: "output_incomplete"

  defp output_error_code(_reason), do: "extraction_failed"
end
