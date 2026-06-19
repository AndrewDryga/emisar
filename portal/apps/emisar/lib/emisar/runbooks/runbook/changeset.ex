defmodule Emisar.Runbooks.Runbook.Changeset do
  use Emisar, :changeset
  alias Emisar.Runbooks.{Runbook, StepSelector}

  @fields ~w[name slug title description status definition]a

  # Each step's `id` is the dispatch identity: runs are matched to plan rows
  # by `{step_id, runner_id}` and that pair is the `action_runs` unique index.
  # A duplicate id makes two distinct steps collide — one is treated as
  # already-dispatched and silently skipped — so a published runbook must give
  # every step a bounded, non-empty, definition-unique id.
  @max_step_id_length 80

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
    do: change(runbook, deleted_at: DateTime.utc_now())

  defp changeset(changeset) do
    changeset
    |> validate_required([:account_id, :name, :slug, :title, :definition])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_format(:slug, ~r/^[a-z][a-z0-9_-]{0,79}$/)
    |> validate_publishable_steps()
    |> unique_constraint([:account_id, :slug, :version])
  end

  # A draft can be an unfinished work-in-progress, but a *published* runbook
  # must actually run: a step with a blank action otherwise publishes fine and
  # only blows up mid-fan-out at dispatch (step_attrs hands a nil action_id to
  # dispatch_run — the worst place to find out), and a step with no runner
  # target has nowhere to run (the engine resolves each step against its own
  # runner_selector). The empty-list case is the dispatch-time :empty_runbook
  # guard pulled forward to save. Surfaced on :definition (no field input) via
  # the editor's save_error_message/1.
  #
  # `get_field` (not validate_change): publish changes only :status, so the
  # existing :definition isn't in `changes` — we must validate its current
  # value, not just an on-change edit.
  defp validate_publishable_steps(changeset) do
    if get_field(changeset, :status) == :published do
      case publishable_steps_error(get_field(changeset, :definition)) do
        nil -> changeset
        message -> add_error(changeset, :definition, message)
      end
    else
      changeset
    end
  end

  defp publishable_steps_error(%{"steps" => steps}) when is_list(steps) and steps != [] do
    cond do
      Enum.any?(steps, &blank_step_action?/1) ->
        "every step needs an action before publishing"

      Enum.any?(steps, &StepSelector.empty?(&1["runner_selector"])) ->
        "every step needs a runner or group target before publishing"

      Enum.any?(steps, &invalid_step_id?/1) ->
        "every step needs an ID of 1–#{@max_step_id_length} characters before publishing"

      duplicate_step_ids?(steps) ->
        "every step needs a unique ID before publishing"

      true ->
        nil
    end
  end

  defp publishable_steps_error(_), do: "add at least one step before publishing"

  defp blank_step_action?(step) do
    action = step["action_id"] || step["action"]
    not (is_binary(action) and String.trim(action) != "")
  end

  defp invalid_step_id?(step) do
    id = step["id"]
    not (is_binary(id) and String.trim(id) != "" and String.length(id) <= @max_step_id_length)
  end

  defp duplicate_step_ids?(steps) do
    ids = Enum.map(steps, & &1["id"])
    ids != Enum.uniq(ids)
  end
end
