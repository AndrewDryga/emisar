defmodule Emisar.Runbooks.Runbook.Changeset do
  use Emisar, :changeset
  alias Emisar.Runbooks.Runbook

  @statuses ~w(draft published)
  @fields ~w[name slug title description status definition]a

  @doc """
  Validation-only changeset for the runbook editor's metadata form. Casts the
  operator-facing text fields (title required + length, slug format when typed)
  so the LiveView can drive `phx-change` validation and render inline field
  errors. `definition`/`steps` are structured editor state, not a text input, so
  they're left out of the cast and validated on save by the real
  `create`/`new_version` changesets.
  """
  def form(attrs \\ %{}) do
    %Runbook{}
    |> cast(attrs, [:title, :slug, :description])
    # Slug is optional in the editor — blank means "auto-derive from title on
    # save", so drop an empty slug before validating its format.
    |> update_change(:slug, &nilify_blank/1)
    |> validate_required([:title])
    |> validate_length(:title, min: 1, max: 80)
    |> validate_format(:slug, ~r/^[a-z][a-z0-9_-]{0,79}$/)
  end

  defp nilify_blank(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp nilify_blank(value), do: value

  def create(account_id, user_id, attrs) do
    %Runbook{}
    |> cast(attrs, @fields)
    |> put_change(:account_id, account_id)
    |> put_change(:created_by_id, user_id)
    |> put_change(:version, 1)
    |> changeset()
  end

  @doc """
  Builds the next version of an existing runbook: carries the prior row's
  fields as the base, applies `attrs` on top, and bumps the version. Keeping
  the carry-over in the struct (not a map merged with `attrs`) avoids mixing
  atom and string keys when `attrs` comes from a form.
  """
  def new_version(%Runbook{} = previous, user_id, attrs) do
    %Runbook{
      name: previous.name,
      slug: previous.slug,
      title: previous.title,
      description: previous.description,
      definition: previous.definition,
      status: previous.status
    }
    |> cast(attrs, @fields)
    |> put_change(:account_id, previous.account_id)
    |> put_change(:created_by_id, user_id)
    |> put_change(:version, previous.version + 1)
    |> changeset()
  end

  def update(%Runbook{} = runbook, attrs) do
    runbook |> cast(attrs, @fields) |> changeset()
  end

  def delete(%Runbook{} = runbook),
    do: change(runbook, deleted_at: now())

  def statuses, do: @statuses

  defp changeset(cs) do
    cs
    |> validate_required([:account_id, :name, :slug, :title, :definition])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_format(:slug, ~r/^[a-z][a-z0-9_-]{0,79}$/)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:account_id, :slug, :version])
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
