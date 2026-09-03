defmodule Emisar.Runbooks.Runbook.Changeset do
  use Emisar, :changeset
  alias Emisar.Runbooks.{Definition, Naming, Runbook}

  # `definition` and `live_version` are never cast: both are decided by
  # `publish/3`, so a client-supplied live definition or version is ignored
  # everywhere. Metadata is not versioned; the DEFINITION is the gated artifact.
  # `id` is castable only on CREATE, where the MCP path supplies the operation's
  # derived identity; a later save must never be able to rewrite a runbook's PK.
  @create_fields ~w[id slug title description]a
  @update_fields ~w[slug title description]a

  # Character counts are the operator's promise; byte ceilings are what the MCP
  # projection budget is derived from. Both are needed: `validate_length/3`
  # counts graphemes, and a grapheme cluster carries no byte bound at all, so a
  # character-only limit let a runbook whose description was well within 4,096
  # characters overflow a budget sized as if it were 4,096 bytes.
  @max_title_bytes 320
  @max_description_bytes 8_192

  @doc "The stored-byte ceiling for a runbook title."
  def max_title_bytes, do: @max_title_bytes

  @doc "The stored-byte ceiling for a runbook description."
  def max_description_bytes, do: @max_description_bytes

  @doc """
  Validation-only metadata changeset for the structured editor. The definition
  is validated separately when a draft is saved or published.
  """
  def form(attrs \\ %{}) do
    %Runbook{}
    |> cast(attrs, [:title, :slug, :description])
    |> update_change(:slug, &nilify_blank/1)
    |> validate_required([:title])
    |> validate_length(:title, min: 1, max: 80)
    |> validate_length(:title, max: @max_title_bytes, count: :bytes)
    |> validate_format(:slug, ~r/\A[a-z][a-z0-9_-]{0,79}\z/)
  end

  @doc "Creates a runbook whose whole content is its first, never-published draft."
  def create(account_id, user_id, attrs) do
    %Runbook{}
    |> cast_details(attrs, @create_fields)
    |> put_change(:account_id, account_id)
    |> put_change(:created_by_id, user_id)
    |> cast(attrs, [:draft_definition])
    |> validate_required([:draft_definition])
    |> validate_draft_definition()
    |> changeset()
    # The MCP path supplies a deterministic `id` derived from the operation, and
    # the 24h operation-dedup row is pruned while this runbook lives on — so a
    # re-derived id can collide with an existing PK. Map that to a tagged conflict
    # instead of an unhandled Ecto.ConstraintError (a 500 for a scheduled agent).
    |> unique_constraint(:id, name: :runbooks_pkey)
  end

  @doc """
  Saves the runbook's metadata and, when one is supplied, its single mutable
  draft.

  Metadata is not versioned, so a title or description edit lands in place and
  leaves the draft alone. The slug is frozen once a release exists — published
  refs depend on it — so a slug change after the first publish is a changeset
  error, not a silent rename.
  """
  def draft(%Runbook{} = runbook, attrs) do
    runbook
    |> cast_details(attrs, @update_fields)
    |> validate_slug_unchanged_after_release()
    |> cast(attrs, [:draft_definition])
    |> validate_draft_definition()
    |> changeset()
  end

  @doc "Promotes the draft to release `version` — the one transition that writes what is live."
  def publish(%Runbook{} = runbook, definition, version) do
    runbook
    |> change(definition: definition, live_version: version, draft_definition: nil)
    |> changeset()
  end

  @doc "Drops the unpublished change, leaving the live release untouched."
  def discard_draft(%Runbook{} = runbook),
    do: runbook |> change(draft_definition: nil) |> changeset()

  def delete(%Runbook{} = runbook),
    do: change(runbook, deleted_at: DateTime.utc_now())

  defp cast_details(runbook_or_changeset, attrs, fields) do
    runbook_or_changeset
    |> cast(attrs, fields)
    |> put_name_from_title()
    |> put_slug_from_title()
  end

  defp changeset(changeset) do
    changeset
    |> validate_required([:account_id, :name, :slug, :title])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_length(:title, min: 1, max: 80)
    |> validate_length(:title, max: @max_title_bytes, count: :bytes)
    |> validate_length(:description, max: 4_096)
    |> validate_length(:description, max: @max_description_bytes, count: :bytes)
    |> validate_format(:slug, ~r/\A[a-z][a-z0-9_-]{0,79}\z/)
    |> unique_constraint([:account_id, :slug])
  end

  defp validate_slug_unchanged_after_release(changeset) do
    if is_nil(changeset.data.live_version) or is_nil(get_change(changeset, :slug)),
      do: changeset,
      else: add_error(changeset, :slug, "cannot change once the runbook has been published")
  end

  defp validate_draft_definition(changeset) do
    case draft_definition_issues(changeset) do
      :unchanged ->
        changeset

      {:ok, _definition} ->
        changeset

      {:error, [first | rest]} ->
        suffix = if rest == [], do: "", else: " (+#{length(rest)} more)"

        add_error(
          changeset,
          :draft_definition,
          "#{first.message} at #{first.path}#{suffix}",
          code: first.code,
          path: first.path,
          issues: [first | rest]
        )
    end
  end

  # A save that carries no definition is a metadata edit; the draft it leaves
  # untouched was already validated when it was written.
  defp draft_definition_issues(changeset) do
    case get_change(changeset, :draft_definition) do
      nil -> :unchanged
      definition -> Definition.validate_draft(definition)
    end
  end

  defp put_name_from_title(changeset) do
    case get_field(changeset, :title) do
      title when is_binary(title) -> put_change(changeset, :name, title)
      _missing -> changeset
    end
  end

  defp put_slug_from_title(changeset) do
    case {get_field(changeset, :slug), get_field(changeset, :title)} do
      {slug, title} when is_binary(title) ->
        case Naming.resolve_slug(title, slug) do
          ^slug -> changeset
          resolved -> put_change(changeset, :slug, resolved)
        end

      _missing ->
        changeset
    end
  end

  defp nilify_blank(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp nilify_blank(value), do: value
end
