defmodule EmisarWeb.MCP.RunbookContract do
  @moduledoc """
  Bounded, lossless MCP projection of the canonical runbook definition.

  The Runbooks context owns validation and definition identity. MCP keeps row
  metadata separate and exposes the same JSON-compatible definition used by
  persistence and the console editor.
  """

  alias Emisar.Auth.Subject
  alias Emisar.Runbooks

  # The projection budget is DERIVED from the byte bounds the authoring path
  # enforces, so a runbook saved within the documented limits always fits rather
  # than disappearing from MCP. A guessed cap is what let a valid non-ASCII
  # runbook overflow: the definition limit is bytes, but `title`/`description`
  # were bounded in graphemes, which carry no byte bound at all.
  #
  # Derived is not guaranteed: JSON escaping expands a control character to six
  # bytes, so a hostile title or description can still overflow. That is why
  # `fit/1` measures the encoded projection and `project/2` reports the overflow
  # as its own outcome instead of collapsing it into a resolution failure.
  # The envelope covers the refs, digest, status, counts, family, and JSON keys
  # that wrap the three bounded values; measured at ~600 bytes worst case.
  @max_envelope_bytes 1_024
  @max_projection_bytes Runbooks.definition_limit!(:max_definition_bytes) +
                          Runbooks.metadata_limit!(:title_bytes) +
                          Runbooks.metadata_limit!(:description_bytes) + @max_envelope_bytes

  # The list summary's own bound. JSON Schema counts `maxLength` in code points,
  # so the slice is taken in code points too — `String.slice/3` counts graphemes,
  # and a cluster can carry several code points past a limit that looks obeyed.
  @max_text_summary_codepoints 512

  @doc "The encoded-byte ceiling one runbook projection may occupy."
  def max_projection_bytes, do: @max_projection_bytes

  @doc """
  Maps each slug to its family lifecycle pair — the version that runs today and
  the pending draft above it.

  Every runbook projection carries this pair because either side alone is
  ambiguous to a model: a published version never mentions the revision waiting
  behind it, and a draft never mentions what production is still running.
  Returns `{:ok, %{slug => family}}` or `{:error, :unauthorized}`.
  """
  def families(slugs, %Subject{} = subject) when is_list(slugs) do
    with {:ok, published} <- Runbooks.latest_published_by_slugs(slugs, subject),
         {:ok, drafts} <- Runbooks.draft_heads_by_slugs(slugs, subject) do
      {:ok, Map.new(slugs, &{&1, family(published[&1], drafts[&1])})}
    end
  end

  @doc """
  Returns one complete immutable runbook projection.

  Fails `:incomplete_contract` when the stored definition is not canonical, and
  `{:runbook_too_large, bytes}` when a valid runbook simply exceeds the budget.
  The two are deliberately distinct: an unresolvable pack or runner must stay
  indistinguishable from a runbook that does not exist, but a size limit is a
  mechanical fact the operator is entitled to be told.
  """
  def project(runbook, family), do: projected(runbook, family, "published")

  @doc "Returns one canonical immutable draft projection with its test identity."
  def project_draft(runbook, family), do: projected(runbook, family, "draft")

  @doc """
  Returns the bounded list summary for one runbook.

  The summary carries no definition, so it is emitted whether or not the full
  projection fits: an oversized runbook stays discoverable and says why it can
  only be opened in the console.
  """
  def summarize(runbook, family, status) do
    with {:ok, projection} <- build(runbook, family, status) do
      {:ok, summary_entry(runbook, projection, fit(projection))}
    end
  end

  @doc "The immutable `slug@version` wire identity of one runbook row."
  def runbook_ref(runbook), do: "#{runbook.slug}@#{runbook.version}"

  @doc "Returns bounded counts used by list results and human summaries."
  def summary(%{"inputs" => inputs, "stages" => stages}) do
    %{
      input_count: length(inputs),
      stage_count: length(stages),
      step_count: Enum.sum(Enum.map(stages, &length(&1["steps"])))
    }
  end

  defp projected(runbook, family, status) do
    with {:ok, projection} <- build(runbook, family, status),
         :ok <- fit(projection) do
      {:ok, projection}
    else
      {:too_large, bytes} -> {:error, {:runbook_too_large, bytes}}
      {:error, :incomplete_contract} -> {:error, :incomplete_contract}
    end
  end

  defp build(runbook, family, "published") do
    case Runbooks.validate_definition(runbook.definition) do
      {:ok, definition} ->
        {:ok,
         %{
           runbook_ref: runbook_ref(runbook),
           status: "published",
           definition_sha256: Runbooks.definition_digest(definition),
           title: runbook.title,
           description: runbook.description,
           definition: definition,
           summary: summary(definition),
           family: family
         }}

      {:error, _issues} ->
        {:error, :incomplete_contract}
    end
  end

  defp build(runbook, family, "draft") do
    case Runbooks.validate_draft_definition(runbook.definition) do
      {:ok, definition} ->
        {:ok,
         %{
           runbook_ref: runbook_ref(runbook),
           draft_id: runbook.id,
           status: "draft",
           definition_sha256: Runbooks.definition_digest(definition),
           title: runbook.title,
           description: runbook.description,
           definition: definition,
           summary: summary(definition),
           family: family
         }}

      {:error, _issues} ->
        {:error, :incomplete_contract}
    end
  end

  defp fit(projection) do
    size = encoded_size(projection)

    if size <= @max_projection_bytes, do: :ok, else: {:too_large, size}
  rescue
    Jason.EncodeError -> {:error, :incomplete_contract}
  end

  defp summary_entry(runbook, projection, fitted) do
    %{
      runbook_ref: projection.runbook_ref,
      status: projection.status,
      definition_sha256: projection.definition_sha256,
      title: runbook.title,
      summary: text_summary(runbook.description),
      family: projection.family,
      input_count: projection.summary.input_count,
      stage_count: projection.summary.stage_count,
      step_count: projection.summary.step_count
    }
    |> put_draft_id(projection)
    |> put_availability(fitted)
  end

  defp put_draft_id(entry, %{draft_id: draft_id}), do: Map.put(entry, :draft_id, draft_id)
  defp put_draft_id(entry, _projection), do: entry

  defp put_availability(entry, :ok), do: Map.put(entry, :available, true)

  defp put_availability(entry, {:too_large, bytes}) do
    Map.merge(entry, %{
      available: false,
      unavailable_reason:
        "This runbook projects to #{bytes} bytes, over the #{@max_projection_bytes} byte limit for one MCP response. Open it in the console to read or run it."
    })
  end

  # An encoding failure on an already-validated definition is not a size fact,
  # so it degrades to the same closed answer the resolution failures give.
  defp put_availability(entry, {:error, :incomplete_contract}),
    do: Map.put(entry, :available, false)

  defp family(published, draft),
    do: %{published_ref: family_ref(published), draft_ref: family_ref(draft)}

  defp family_ref(nil), do: nil
  defp family_ref(runbook), do: runbook_ref(runbook)

  defp text_summary(value) when is_binary(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.codepoints()
    |> Enum.take(@max_text_summary_codepoints)
    |> Enum.join()
  end

  defp text_summary(_value), do: ""

  defp encoded_size(value), do: value |> Jason.encode_to_iodata!() |> IO.iodata_length()
end
