defmodule Emisar.Catalog.TrustedManifest do
  @moduledoc """
  Builds and validates the release- or operator-trusted action descriptors for
  one exact pack version and hash.

  The versioned envelope distinguishes complete manifests from historical
  `trusted_manifest` rows that stored only risk and kind. Those older rows are
  deliberately incomplete for static/MCP reads; they are never upgraded from
  mutable runner advertisements.
  """

  alias Emisar.Catalog.RunnerAction

  @schema_version 1
  @manifest_fields ~w(actions schema_version)
  @descriptor_fields ~w(
    args_schema
    description
    examples
    kind
    risk
    search_terms
    side_effects
    summary
    title
  )
  @kinds ~w(exec script)
  @risks ~w(low medium high critical)

  @max_actions 80
  @max_action_id_length 128
  @max_title_length 160
  @max_summary_length 512
  @max_description_length 4_096
  @max_side_effects 16
  @max_side_effect_length 1_024
  @max_examples 16
  @max_search_terms 16
  @max_search_term_length 80
  @max_descriptor_bytes 32_768
  @max_manifest_bytes 1_048_576
  @max_compact_pack_bytes 57_344
  @action_id_format ~r/\A[a-z][a-z0-9_-]*(\.[a-z][a-z0-9_-]*)+\z/
  @unsafe_text ~r/[\p{Cc}\p{Cf}\p{Cs}]/u

  @type t :: %{
          required(String.t()) => 1 | %{required(String.t()) => map()}
        }

  @doc "Build a trusted manifest from release-frozen catalog action objects."
  @spec from_catalog_actions([map()]) :: {:ok, map()} | {:error, :invalid_manifest}
  def from_catalog_actions(actions) when is_list(actions) do
    build(actions, &catalog_descriptor/1)
  end

  def from_catalog_actions(_actions), do: {:error, :invalid_manifest}

  @doc "Build a trusted manifest from the runner rows reviewed by an operator."
  @spec from_runner_actions([RunnerAction.t()]) :: {:ok, map()} | {:error, :invalid_manifest}
  def from_runner_actions(actions) when is_list(actions) do
    build(actions, &runner_descriptor/1)
  end

  def from_runner_actions(_actions), do: {:error, :invalid_manifest}

  @doc "Validate a persisted complete manifest without repairing or coercing it."
  @spec validate(term()) :: {:ok, map()} | {:error, :incomplete_manifest}
  def validate(%{"schema_version" => @schema_version, "actions" => actions} = manifest)
      when is_map(actions) and map_size(manifest) == 2 do
    if manifest |> Map.keys() |> Enum.sort() == @manifest_fields and
         valid_action_count?(actions) and
         Enum.all?(actions, fn {action_id, descriptor} ->
           valid_descriptor?(action_id, descriptor)
         end) and compact_pack_within?(actions) and
         encoded_within?(manifest, @max_manifest_bytes) do
      {:ok, manifest}
    else
      {:error, :incomplete_manifest}
    end
  end

  def validate(_manifest), do: {:error, :incomplete_manifest}

  @doc "Return the action map from a complete persisted manifest."
  @spec actions(term()) :: {:ok, map()} | {:error, :incomplete_manifest}
  def actions(manifest) do
    with {:ok, %{"actions" => actions}} <- validate(manifest), do: {:ok, actions}
  end

  @doc "The deterministic field list compared when a trusted descriptor drifts."
  @spec descriptor_fields() :: [String.t()]
  def descriptor_fields, do: @descriptor_fields

  defp build(actions, descriptor_fun) do
    with true <- length(actions) <= @max_actions,
         {:ok, descriptors} <- build_descriptors(actions, descriptor_fun),
         manifest = %{"schema_version" => @schema_version, "actions" => descriptors},
         {:ok, _manifest} <- validate(manifest) do
      {:ok, manifest}
    else
      _ -> {:error, :invalid_manifest}
    end
  end

  defp build_descriptors(actions, descriptor_fun) do
    Enum.reduce_while(actions, {:ok, %{}}, fn action, {:ok, descriptors} ->
      with {:ok, action_id, descriptor} <- descriptor_fun.(action),
           :ok <- put_descriptor_check(descriptors, action_id, descriptor) do
        {:cont, {:ok, Map.put(descriptors, action_id, descriptor)}}
      else
        _ -> {:halt, {:error, :invalid_manifest}}
      end
    end)
  end

  defp put_descriptor_check(descriptors, action_id, descriptor) do
    case Map.fetch(descriptors, action_id) do
      :error -> :ok
      {:ok, ^descriptor} -> :ok
      {:ok, _different} -> {:error, :descriptor_mismatch}
    end
  end

  defp catalog_descriptor(%{} = action) do
    descriptor = %{
      "title" => action["title"],
      "summary" => action["summary"],
      "description" => action["description"],
      "kind" => action["kind"],
      "risk" => action["risk"],
      "side_effects" => action["side_effects"] || [],
      "args_schema" => %{"args" => action["args"] || []},
      "examples" => action["examples"] || [],
      "search_terms" => action["search_terms"] || []
    }

    {:ok, action["id"], descriptor}
  end

  defp catalog_descriptor(_action), do: {:error, :invalid_manifest}

  defp runner_descriptor(%RunnerAction{} = action) do
    descriptor = %{
      "title" => action.title,
      "summary" => action.summary || summary(action.description),
      "description" => action.description,
      "kind" => to_string(action.kind),
      "risk" => to_string(action.risk),
      "side_effects" => action.side_effects || [],
      "args_schema" => action.args_schema || %{},
      "examples" => action.examples || [],
      "search_terms" => action.search_terms || []
    }

    {:ok, action.action_id, descriptor}
  end

  defp runner_descriptor(_action), do: {:error, :invalid_manifest}

  defp summary(description) when is_binary(description) do
    description
    |> String.split()
    |> Enum.join(" ")
    |> String.slice(0, @max_summary_length)
  end

  defp summary(_description), do: nil

  defp valid_action_count?(actions), do: map_size(actions) <= @max_actions

  defp valid_descriptor?(action_id, %{} = descriptor) do
    descriptor |> Map.keys() |> Enum.sort() == @descriptor_fields and
      valid_action_id?(action_id) and
      valid_string?(descriptor["title"], 1, @max_title_length) and
      valid_string?(descriptor["summary"], 1, @max_summary_length) and
      valid_string?(descriptor["description"], 1, @max_description_length) and
      descriptor["kind"] in @kinds and
      descriptor["risk"] in @risks and
      valid_string_list?(
        descriptor["side_effects"],
        @max_side_effects,
        @max_side_effect_length,
        false
      ) and
      valid_args_schema?(descriptor["args_schema"]) and
      valid_map_list?(descriptor["examples"], @max_examples) and
      valid_string_list?(
        descriptor["search_terms"],
        @max_search_terms,
        @max_search_term_length,
        true
      ) and
      safe_model_value?(descriptor) and
      encoded_within?(descriptor, @max_descriptor_bytes)
  end

  defp valid_descriptor?(_action_id, _descriptor), do: false

  defp valid_action_id?(action_id) do
    valid_string?(action_id, 1, @max_action_id_length) and
      Regex.match?(@action_id_format, action_id)
  end

  defp valid_string?(value, min, max) when is_binary(value) do
    String.valid?(value) and String.length(value) in min..max
  end

  defp valid_string?(_value, _min, _max), do: false

  defp valid_string_list?(values, max_items, max_length, distinct?) when is_list(values) do
    length(values) <= max_items and
      Enum.all?(values, &valid_string?(&1, 1, max_length)) and
      (not distinct? or case_insensitively_distinct?(values))
  end

  defp valid_string_list?(_values, _max_items, _max_length, _distinct?), do: false

  defp valid_args_schema?(%{"args" => args} = schema)
       when map_size(schema) == 1 and is_list(args),
       do: Enum.all?(args, &is_map/1)

  defp valid_args_schema?(_schema), do: false

  defp valid_map_list?(values, max_items) when is_list(values),
    do: length(values) <= max_items and Enum.all?(values, &is_map/1)

  defp valid_map_list?(_values, _max_items), do: false

  defp compact_pack_within?(actions) do
    action_summaries =
      Enum.map(actions, fn {action_id, descriptor} ->
        %{
          "action_id" => action_id,
          "title" => descriptor["title"],
          "summary" => descriptor["summary"],
          "risk" => descriptor["risk"],
          "availability" => "unavailable"
        }
      end)

    worst_case_issue = %{
      "code" => String.duplicate("x", 80),
      "message" => String.duplicate("\u00E9", 512)
    }

    encoded_within?(
      %{
        "pack_ref" => String.duplicate("x", 256),
        "availability" => "unavailable",
        "issues" => List.duplicate(worst_case_issue, 8),
        "actions" => action_summaries
      },
      @max_compact_pack_bytes
    )
  end

  defp case_insensitively_distinct?(values) do
    normalized = Enum.map(values, &String.downcase/1)
    Enum.uniq(normalized) == normalized
  end

  defp safe_model_value?(value) when is_binary(value) do
    String.valid?(value) and not Regex.match?(@unsafe_text, value)
  end

  defp safe_model_value?(%{} = value) do
    Enum.all?(value, fn {key, child} -> safe_model_value?(key) and safe_model_value?(child) end)
  end

  defp safe_model_value?(value) when is_list(value), do: Enum.all?(value, &safe_model_value?/1)
  defp safe_model_value?(value), do: is_number(value) or is_boolean(value) or is_nil(value)

  defp encoded_within?(value, max_bytes) do
    case Jason.encode(value) do
      {:ok, encoded} -> byte_size(encoded) <= max_bytes
      {:error, _error} -> false
    end
  end
end
