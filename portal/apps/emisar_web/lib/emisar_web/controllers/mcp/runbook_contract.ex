defmodule EmisarWeb.MCP.RunbookContract do
  @moduledoc """
  Bounded, lossless MCP projection of the canonical runbook definition.

  The Runbooks context owns validation and definition identity. MCP keeps row
  metadata separate and exposes the same JSON-compatible definition used by
  persistence and the console editor.
  """

  alias Emisar.Auth.Subject
  alias Emisar.Runbooks

  @max_projection_bytes 72 * 1_024

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

  @doc "Returns one complete immutable runbook projection or fails closed."
  def project(runbook, family) do
    with {:ok, definition} <- Runbooks.validate_definition(runbook.definition),
         projection <- %{
           runbook_ref: runbook_ref(runbook),
           status: "published",
           definition_sha256: Runbooks.definition_digest(definition),
           title: runbook.title,
           description: runbook.description,
           definition: definition,
           summary: summary(definition),
           family: family
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
  def project_draft(runbook, family) do
    with {:ok, definition} <- Runbooks.validate_draft_definition(runbook.definition),
         projection <- %{
           runbook_ref: runbook_ref(runbook),
           draft_id: runbook.id,
           status: "draft",
           definition_sha256: Runbooks.definition_digest(definition),
           title: runbook.title,
           description: runbook.description,
           definition: definition,
           summary: summary(definition),
           family: family
         },
         true <- encoded_size(projection) <= @max_projection_bytes do
      {:ok, projection}
    else
      _invalid_or_oversized -> {:error, :incomplete_contract}
    end
  rescue
    Jason.EncodeError -> {:error, :incomplete_contract}
  end

  @doc "The immutable `slug@version` wire identity of one runbook row."
  def runbook_ref(runbook), do: "#{runbook.slug}@#{runbook.version}"

  defp family(published, draft),
    do: %{published_ref: family_ref(published), draft_ref: family_ref(draft)}

  defp family_ref(nil), do: nil
  defp family_ref(runbook), do: runbook_ref(runbook)

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
