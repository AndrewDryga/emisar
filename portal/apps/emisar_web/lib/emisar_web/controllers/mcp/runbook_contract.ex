defmodule EmisarWeb.MCP.RunbookContract do
  @moduledoc """
  Bounded, lossless MCP projection of the canonical runbook definition.

  The Runbooks context owns validation and definition identity. MCP keeps row
  metadata separate and exposes the same JSON-compatible definition used by
  persistence and the console editor.
  """

  alias Emisar.Runbooks

  @max_projection_bytes 72 * 1_024

  @doc "Returns one complete immutable runbook projection or fails closed."
  def project(runbook) do
    with {:ok, definition} <- Runbooks.validate_definition(runbook.definition),
         projection <- %{
           runbook_ref: "#{runbook.slug}@#{runbook.version}",
           status: "published",
           definition_sha256: Runbooks.definition_digest(definition),
           title: runbook.title,
           description: runbook.description,
           definition: definition,
           summary: summary(definition)
         },
         true <- encoded_size(projection) <= @max_projection_bytes do
      {:ok, projection}
    else
      _invalid_or_oversized -> {:error, :incomplete_contract}
    end
  rescue
    Jason.EncodeError -> {:error, :incomplete_contract}
  end

  @doc "Returns one canonical immutable draft projection with its test identity."
  def project_draft(runbook) do
    with {:ok, definition} <- Runbooks.validate_draft_definition(runbook.definition),
         projection <- %{
           runbook_ref: "#{runbook.slug}@#{runbook.version}",
           draft_id: runbook.id,
           status: "draft",
           definition_sha256: Runbooks.definition_digest(definition),
           title: runbook.title,
           description: runbook.description,
           definition: definition,
           summary: summary(definition)
         },
         true <- encoded_size(projection) <= @max_projection_bytes do
      {:ok, projection}
    else
      _invalid_or_oversized -> {:error, :incomplete_contract}
    end
  rescue
    Jason.EncodeError -> {:error, :incomplete_contract}
  end

  @doc "Returns bounded counts used by list results and human summaries."
  def summary(%{"inputs" => inputs, "stages" => stages}) do
    %{
      input_count: length(inputs),
      stage_count: length(stages),
      step_count: Enum.sum(Enum.map(stages, &length(&1["steps"])))
    }
  end

  defp encoded_size(value), do: value |> Jason.encode_to_iodata!() |> IO.iodata_length()
end
