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
  alias Emisar.Crypto

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
  # Typed actions additionally carry their opt-in output contract; a descriptor
  # without one never has the key, so absence stays distinguishable from nil.
  @descriptor_fields_with_output_schema Enum.sort(["output_schema" | @descriptor_fields])
  @kinds ~w(exec script)
  @risks ~w(low medium high critical)

  # A deeply covered service outgrows a round number: cassandra reached 119
  # actions once its runtime limits, configuration, and administrative verbs
  # were declared rather than left to a shell. The byte bounds below are what
  # actually protect the manifest and the compact pack an operator reviews.
  @max_actions 120
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
  @max_output_schema_bytes 8_192
  @max_manifest_bytes 1_048_576
  @max_compact_pack_bytes 57_344
  @action_id_format ~r/\A[a-z][a-z0-9_-]*(\.[a-z][a-z0-9_-]*)+\z/
  @unsafe_text ~r/[\p{Cc}\p{Cf}\p{Cs}]/u

  @type t :: %{
          required(String.t()) => 1 | %{required(String.t()) => map()}
        }

  @doc "Maximum actions a complete trusted pack manifest may contain."
  def max_actions, do: @max_actions

  @doc "Build a trusted manifest from published catalog action objects."
  @spec from_catalog_actions([map()]) :: {:ok, map()} | {:error, :invalid_manifest}
  def from_catalog_actions(actions) when is_list(actions) do
    case build(actions, &catalog_descriptor/1) do
      {:ok, manifest} -> {:ok, manifest}
      # Published catalog actions have no runner to blame — a conflicting
      # duplicate id in the baseline is a build defect, plain invalidity.
      {:error, _reason} -> {:error, :invalid_manifest}
    end
  end

  def from_catalog_actions(_actions), do: {:error, :invalid_manifest}

  @doc """
  Build a trusted manifest from the runner rows reviewed by an operator.

  Conflicting advertisements for one action id surface as
  `{:error, {:descriptor_mismatch, action_id}}` so the trust flow can name
  the disagreeing runners instead of failing generically.
  """
  @spec from_runner_actions([RunnerAction.t()]) ::
          {:ok, map()} | {:error, :invalid_manifest | {:descriptor_mismatch, String.t()}}
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

  @doc """
  Content digest of one complete descriptor — what a catalog listing compares
  instead of re-reading every descriptor column of every advertised action.

  Equality of digests is equality of descriptors: the digest covers the same
  map `from_runner_actions/1` builds, so a drifted field changes it.
  """
  @spec descriptor_digest(map()) :: String.t()
  def descriptor_digest(%{} = descriptor),
    do: descriptor |> canonical() |> Jason.encode!() |> Crypto.hash_hex()

  @doc """
  Digest of what a runner advertised for one action, in the manifest's own
  descriptor shape — the value the catalog stores per row.

  Computed here rather than at the call site so the ingest and the manifest
  comparison can never disagree about which fields the descriptor is.
  """
  @spec runner_action_digest(RunnerAction.t()) :: String.t()
  def runner_action_digest(%RunnerAction{} = action),
    do: action |> advertised_descriptor() |> descriptor_digest()

  # A descriptor's identity is its field VALUES, not their storage order, and a
  # map holding more than 32 keys iterates in an order Erlang does not promise
  # across releases. So the digest is taken over a recursively key-sorted
  # encoding — never over a raw map, which would digest the same descriptor two
  # ways and read as permanent drift.
  defp canonical(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> [key, canonical(value)] end)
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value

  defp build(actions, descriptor_fun) do
    with {:ok, descriptors} <- build_descriptors(actions, descriptor_fun),
         manifest = %{"schema_version" => @schema_version, "actions" => descriptors},
         {:ok, _manifest} <- validate(manifest) do
      {:ok, manifest}
    else
      {:error, {:descriptor_mismatch, action_id}} -> {:error, {:descriptor_mismatch, action_id}}
      _ -> {:error, :invalid_manifest}
    end
  end

  defp build_descriptors(actions, descriptor_fun) do
    Enum.reduce_while(actions, {:ok, %{}}, fn action, {:ok, descriptors} ->
      with {:ok, action_id, descriptor} <- descriptor_fun.(action),
           :ok <- put_descriptor_check(descriptors, action_id, descriptor) do
        {:cont, {:ok, Map.put(descriptors, action_id, descriptor)}}
      else
        {:error, {:descriptor_mismatch, action_id}} ->
          {:halt, {:error, {:descriptor_mismatch, action_id}}}

        _ ->
          {:halt, {:error, :invalid_manifest}}
      end
    end)
  end

  defp put_descriptor_check(descriptors, action_id, descriptor) do
    case Map.fetch(descriptors, action_id) do
      :error -> :ok
      {:ok, ^descriptor} -> :ok
      {:ok, _different} -> {:error, {:descriptor_mismatch, action_id}}
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

    with {:ok, descriptor} <- put_output_schema(descriptor, action["output_schema"]) do
      {:ok, action["id"], descriptor}
    end
  end

  defp catalog_descriptor(_action), do: {:error, :invalid_manifest}

  defp runner_descriptor(%RunnerAction{} = action),
    do: {:ok, action.action_id, advertised_descriptor(action)}

  defp runner_descriptor(_action), do: {:error, :invalid_manifest}

  # The advertised descriptor is assembled without judging it — `validate/1`
  # owns that — because the digest has to cover exactly the bytes the manifest
  # comparison would see, including a schema the manifest will go on to reject.
  defp advertised_descriptor(%RunnerAction{} = action) do
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

    put_advertised_output_schema(descriptor, action.output_schema)
  end

  # Trusted descriptors omit the key for untyped actions, so the advertised side
  # must too, or every typed action reads as a permanent mismatch.
  defp put_advertised_output_schema(descriptor, nil), do: descriptor

  defp put_advertised_output_schema(descriptor, schema),
    do: Map.put(descriptor, "output_schema", schema)

  defp put_output_schema(descriptor, nil), do: {:ok, descriptor}

  defp put_output_schema(descriptor, %{} = schema) do
    if Emisar.OutputSchema.valid?(schema) do
      {:ok, Map.put(descriptor, "output_schema", schema)}
    else
      {:error, :invalid_manifest}
    end
  end

  defp put_output_schema(_descriptor, _schema), do: {:error, :invalid_manifest}

  defp summary(description) when is_binary(description) do
    description
    |> String.split()
    |> Enum.join(" ")
    |> String.slice(0, @max_summary_length)
  end

  defp summary(_description), do: nil

  defp valid_action_count?(actions), do: map_size(actions) <= @max_actions

  defp valid_descriptor?(action_id, %{} = descriptor) do
    valid_descriptor_fields?(descriptor) and
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
      valid_output_schema?(descriptor) and
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

  defp valid_descriptor_fields?(descriptor) do
    keys = descriptor |> Map.keys() |> Enum.sort()
    keys == @descriptor_fields or keys == @descriptor_fields_with_output_schema
  end

  defp valid_output_schema?(descriptor) do
    case Map.fetch(descriptor, "output_schema") do
      :error ->
        true

      {:ok, schema} ->
        Emisar.OutputSchema.valid?(schema) and encoded_within?(schema, @max_output_schema_bytes)
    end
  end

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
