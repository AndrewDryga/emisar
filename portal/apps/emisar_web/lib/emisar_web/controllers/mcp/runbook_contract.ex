defmodule EmisarWeb.MCP.RunbookContract do
  @moduledoc """
  Bounded, lossless MCP projection of the canonical runbook definition.

  The Runbooks context owns validation and definition identity. MCP keeps row
  metadata separate and exposes the same JSON-compatible definition used by
  persistence and the console editor.
  """

  alias Emisar.Runbooks

  # The projection budget is DERIVED from the byte bounds the authoring path
  # enforces, so a runbook saved within the documented limits always fits rather
  # than disappearing from MCP. A guessed cap is what let a valid non-ASCII
  # runbook overflow: the definition limit is bytes, but `title`/`description`
  # were bounded in graphemes, which carry no byte bound at all.
  #
  # Derived is not guaranteed: JSON escaping expands a control character to six
  # bytes, so a hostile title or description can still overflow. That is why
  # `fit/1` measures the encoded projection and `project/1` reports the overflow
  # as its own outcome instead of collapsing it into a resolution failure.
  # The envelope covers the refs, both digests, status, counts, and JSON keys
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
  Returns one complete live runbook projection.

  Fails `:incomplete_contract` when the stored definition is not canonical, and
  `{:runbook_too_large, bytes}` when a valid runbook simply exceeds the budget.
  The two are deliberately distinct: an unresolvable pack or runner must stay
  indistinguishable from a runbook that does not exist, but a size limit is a
  mechanical fact the operator is entitled to be told.
  """
  def project(runbook), do: projected(runbook, "published")

  @doc "Returns one canonical draft projection with its test identity."
  def project_draft(runbook), do: projected(runbook, "draft")

  @doc """
  Returns the bounded list summary for one runbook.

  The summary carries no definition, so it is emitted whether or not the full
  projection fits: an oversized runbook stays discoverable and says why it can
  only be opened in the console. Counts and availability describe the live
  release, or the unpublished change while nothing is live yet.
  """
  def summarize(runbook) do
    with {:ok, projection} <- build(runbook, listed_status(runbook)) do
      {:ok, summary_entry(runbook, projection, fit(projection))}
    end
  end

  @doc "The `slug@release` wire identity of one runbook's live release, or nil when it has none."
  def live_ref(%{live_version: nil}), do: nil
  def live_ref(runbook), do: "#{runbook.slug}@#{runbook.live_version}"

  @doc "Returns bounded counts used by list results and human summaries."
  def summary(%{"inputs" => inputs, "stages" => stages}) do
    %{
      input_count: length(inputs),
      stage_count: length(stages),
      step_count: Enum.sum(Enum.map(stages, &length(&1["steps"])))
    }
  end

  defp projected(runbook, status) do
    with {:ok, projection} <- build(runbook, status),
         :ok <- fit(projection) do
      {:ok, projection}
    else
      {:too_large, bytes} -> {:error, {:runbook_too_large, bytes}}
      {:error, :incomplete_contract} -> {:error, :incomplete_contract}
    end
  end

  # Nothing live yet means the unpublished change IS the runbook, so it is what
  # the list describes; once a release exists, the list describes what runs.
  defp listed_status(%{live_version: nil}), do: "draft"
  defp listed_status(_runbook), do: "published"

  defp build(runbook, "published") do
    case Runbooks.validate_definition(runbook.definition) do
      {:ok, definition} ->
        {:ok,
         %{
           runbook_ref: live_ref(runbook),
           status: "published",
           definition_sha256: Runbooks.definition_digest(definition),
           title: runbook.title,
           description: runbook.description,
           definition: definition,
           summary: summary(definition),
           draft_definition_sha256: draft_digest(runbook)
         }}

      {:error, _issues} ->
        {:error, :incomplete_contract}
    end
  end

  defp build(runbook, "draft") do
    case Runbooks.validate_draft_definition(runbook.draft_definition) do
      {:ok, definition} ->
        {:ok,
         %{
           slug: runbook.slug,
           draft_id: runbook.id,
           status: "draft",
           definition_sha256: Runbooks.definition_digest(definition),
           title: runbook.title,
           description: runbook.description,
           definition: definition,
           summary: summary(definition),
           live_ref: live_ref(runbook)
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
      slug: runbook.slug,
      title: runbook.title,
      summary: text_summary(runbook.description),
      live: live_side(runbook),
      draft: draft_side(runbook),
      input_count: projection.summary.input_count,
      stage_count: projection.summary.stage_count,
      step_count: projection.summary.step_count
    }
    |> put_availability(fitted)
  end

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

  # Either side alone is ambiguous to a model: what runs today never mentions
  # the change waiting behind it, and a change never mentions what production is
  # still running. One row answers both, so every projection states both.
  defp live_side(%{live_version: nil}), do: nil

  defp live_side(runbook) do
    %{
      runbook_ref: live_ref(runbook),
      definition_sha256: Runbooks.definition_digest(runbook.definition)
    }
  end

  defp draft_side(%{draft_definition: nil}), do: nil
  defp draft_side(runbook), do: %{definition_sha256: draft_digest(runbook)}

  defp draft_digest(%{draft_definition: nil}), do: nil
  defp draft_digest(runbook), do: Runbooks.definition_digest(runbook.draft_definition)

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
