defmodule Emisar.Catalog.RunnerAction.Changeset do
  use Emisar, :changeset
  alias Emisar.Catalog.RunnerAction

  @fields ~w[
    account_id runner_id action_id pack_id pack_version pack_hash title kind risk
    summary description side_effects args_schema output_schema examples search_terms
    primary_executable_available missing_executable
    first_seen_at last_seen_at
  ]a

  # Re-advertisement of an already-seen action: refresh every field but the
  # immutable first_seen_at. Same validations as insert so an invalid
  # kind/risk in a later advertisement can't force-write past the whitelist.
  @update_fields @fields -- [:first_seen_at]

  # Generous caps on the runner-advertised descriptor. A frame is bounded to
  # ~1 MB by the socket, but a hostile authenticated runner could advertise
  # many fat actions to grow its account's catalog (and every UI/MCP render of
  # it). `title` is a short label (255); a `description` is prose (4 KB). The
  # jsonb/array fields (args_schema, examples, side_effects) are structured
  # data a real pack keeps to a few KB, so 64 KB serialized each is well above
  # any honest descriptor while bounding the gross-abuse row.
  @max_title_length 255
  @max_summary_length 512
  @max_description_length 4_096
  @max_json_bytes 65_536
  @json_fields ~w[args_schema examples side_effects search_terms]a
  @max_output_schema_bytes 8_192

  # action_id is unbounded by the socket frame alone, yet it becomes the MCP
  # tool NAME and renders on every UI/MCP surface — so a hostile runner could
  # advertise a megabyte-long or garbage id. Mirror the runner's own action-id
  # rule (runner/pkg/actionspec/action.go `validActionID`): "<ns>.<name>" with
  # optional extra dot segments, each `[a-z][a-z0-9_-]*`, whole thing ≤ 128.
  # Every trusted pack's id already satisfies this (verified against the
  # bundled catalog), so it's defense-in-depth, not a live break. Anchored
  # with \A…\z, not ^…$, so a trailing-newline id can't slip past. The
  # connector 64-char/no-dot tool-name limits are per-platform mapping concerns,
  # not enforced here — a shared bound would reject the legitimate dotted ids
  # we accept.
  @max_action_id_length 128
  @action_id_format ~r/\A[a-z][a-z0-9_-]*(\.[a-z][a-z0-9_-]*)+\z/
  @max_search_terms 16
  @max_search_term_length 80

  def upsert(attrs) do
    %RunnerAction{}
    |> cast(attrs, @fields)
    |> shared()
  end

  def update(%RunnerAction{} = action, attrs) do
    action
    |> cast(attrs, @update_fields)
    |> shared()
  end

  defp shared(changeset) do
    changeset
    |> validate_required([:account_id, :runner_id, :action_id, :title, :kind, :risk])
    |> validate_length(:action_id, max: @max_action_id_length)
    |> validate_format(:action_id, @action_id_format)
    |> validate_length(:title, max: @max_title_length)
    |> validate_length(:summary, max: @max_summary_length)
    |> validate_length(:description, max: @max_description_length)
    |> validate_length(:missing_executable, max: 255)
    |> validate_length(:search_terms, max: @max_search_terms)
    |> validate_search_terms()
    |> validate_json_sizes()
    |> validate_json_value(:output_schema,
      max_bytes: @max_output_schema_bytes,
      max_depth: 16,
      max_nodes: 512
    )
    |> validate_output_schema_contract()
    |> unique_constraint([:runner_id, :action_id])
    |> check_constraint(:missing_executable,
      name: :missing_executable_requires_unavailable,
      message: "is only valid for an unavailable primary executable"
    )
  end

  defp validate_json_sizes(changeset) do
    Enum.reduce(@json_fields, changeset, &validate_json_size(&2, &1, @max_json_bytes))
  end

  defp validate_output_schema_contract(changeset) do
    if Keyword.has_key?(changeset.errors, :output_schema) do
      changeset
    else
      validate_change(changeset, :output_schema, fn :output_schema, schema ->
        if Emisar.OutputSchema.valid?(schema),
          do: [],
          else: [output_schema: "must be a valid local Draft 2020-12 object schema"]
      end)
    end
  end

  defp validate_search_terms(changeset) do
    validate_change(changeset, :search_terms, fn :search_terms, terms ->
      if Enum.all?(terms, &(String.length(&1) in 1..@max_search_term_length)) do
        []
      else
        [
          search_terms:
            "must contain non-empty strings of at most #{@max_search_term_length} characters"
        ]
      end
    end)
  end
end
