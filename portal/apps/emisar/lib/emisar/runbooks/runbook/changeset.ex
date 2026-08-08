defmodule Emisar.Runbooks.Runbook.Changeset do
  use Emisar, :changeset
  alias Emisar.Runbooks.{Definition, Naming, Runbook}

  # Status is never cast: every status is decided by a named transition
  # (`create`, `create_published`, `new_version`, `new_published_version`,
  # `publish`), so a client-supplied status is ignored everywhere.
  @fields ~w[id slug title description definition]a

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
    |> validate_format(:slug, ~r/^[a-z][a-z0-9_-]{0,79}$/)
  end

  @doc "Create a bounded, potentially incomplete v1 draft. Client status is never cast."
  def create(account_id, user_id, attrs) do
    attrs
    |> new_runbook(account_id, user_id)
    |> put_change(:status, :draft)
    |> changeset()
  end

  @doc "Create a strict v1 runbook already published through the named transition."
  def create_published(account_id, user_id, attrs) do
    attrs
    |> new_runbook(account_id, user_id)
    |> put_change(:status, :published)
    |> changeset()
  end

  defp new_runbook(attrs, account_id, user_id) do
    %Runbook{}
    |> cast(attrs, @fields)
    |> put_change(:account_id, account_id)
    |> put_change(:created_by_id, user_id)
    |> put_change(:version, 1)
    |> put_name_from_title()
    |> put_slug_from_title()
  end

  @doc "Build the next immutable version, always born a draft."
  def new_version(%Runbook{} = previous, user_id, attrs) do
    previous
    |> version_seed(user_id, attrs)
    |> put_change(:status, :draft)
    |> changeset()
  end

  @doc "Build the next immutable version born published through the named transition."
  def new_published_version(%Runbook{} = previous, user_id, attrs) do
    previous
    |> version_seed(user_id, attrs)
    |> put_change(:status, :published)
    |> changeset()
  end

  @doc "Publish an existing immutable version in place through the named transition."
  def publish(%Runbook{} = runbook) do
    runbook
    |> change(status: :published)
    |> changeset()
  end

  defp version_seed(%Runbook{} = previous, user_id, attrs) do
    %Runbook{
      name: previous.name,
      slug: previous.slug,
      title: previous.title,
      description: previous.description,
      definition: previous.definition
    }
    |> cast(attrs, @fields)
    |> put_change(:account_id, previous.account_id)
    |> put_change(:created_by_id, user_id)
    |> put_change(:version, previous.version + 1)
    |> put_name_from_title()
    |> put_slug_from_title()
  end

  def update(%Runbook{} = runbook, attrs) do
    runbook
    |> cast(attrs, @fields)
    |> put_name_from_title()
    |> put_slug_from_title()
    |> changeset()
  end

  def delete(%Runbook{} = runbook),
    do: change(runbook, deleted_at: DateTime.utc_now())

  defp changeset(changeset) do
    changeset
    |> validate_required([:account_id, :name, :slug, :title, :definition])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_length(:title, min: 1, max: 80)
    |> validate_length(:title, max: @max_title_bytes, count: :bytes)
    |> validate_length(:description, max: 4_096)
    |> validate_length(:description, max: @max_description_bytes, count: :bytes)
    |> validate_format(:slug, ~r/^[a-z][a-z0-9_-]{0,79}$/)
    |> validate_definition()
    |> unique_constraint([:account_id, :slug, :version])
  end

  defp validate_definition(changeset) do
    validator =
      if get_field(changeset, :status) == :published,
        do: &Definition.validate/1,
        else: &Definition.validate_draft/1

    case validator.(get_field(changeset, :definition)) do
      {:ok, _definition} ->
        changeset

      {:error, [first | rest]} ->
        suffix = if rest == [], do: "", else: " (+#{length(rest)} more)"

        add_error(
          changeset,
          :definition,
          "#{first.message} at #{first.path}#{suffix}",
          code: first.code,
          path: first.path,
          issues: [first | rest]
        )
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
