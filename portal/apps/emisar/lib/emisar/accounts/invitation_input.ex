defmodule Emisar.Accounts.InvitationInput do
  @moduledoc """
  One invitation submission — the invitee's address, the role being granted, and
  the runner reach that comes with it. Never persisted: `Accounts` casts the raw
  form params through it, so the browser form and the write share ONE definition
  of a valid invitation and a crafted role or runner selector is a field error at
  the context boundary instead of a widened grant.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Emisar.Accounts.RunnerAccess

  @primary_key false
  embedded_schema do
    field :email, :string
    # The role and mode travel as strings because that is what the browser
    # posts; `Membership.role` itself is the canonical atom enum.
    field :role, :string, default: "operator"
    field :runner_access_mode, :string, default: "none"
    field :scope, {:array, :string}, default: []

    # The canonical access the validated selection resolved to.
    field :runner_access, :any, virtual: true
  end

  @fields ~w[email role runner_access_mode scope]a

  @doc """
  Casts one invitation submission against `runners` — the account's current
  `%{id: _, group: _}` runner facts the selection is allowlisted against.

  A valid changeset carries the trimmed email, the granted role, and the
  canonical `%RunnerAccess{}` in `:runner_access`, with `:scope` normalized to
  the selectors that survived (a runner a chosen group already covers is
  dropped). An empty selected-runner scope is a `:runner_access_mode` error.
  """
  def changeset(attrs, runners) when is_list(runners) do
    %__MODULE__{}
    |> cast(attrs, @fields)
    |> update_change(:email, &String.trim/1)
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> validate_inclusion(:role, roles())
    |> validate_inclusion(:runner_access_mode, modes())
    |> validate_runner_access(runners)
  end

  # Read at runtime: pinning these into module attributes would make this input
  # schema a COMPILE dependency of Auth, closing a cycle back through Accounts.
  defp roles, do: Enum.map(Emisar.Auth.roles(), &Atom.to_string/1)
  defp modes, do: Enum.map(RunnerAccess.modes(), &Atom.to_string/1)

  defp validate_runner_access(%Ecto.Changeset{} = changeset, runners) do
    mode = get_field(changeset, :runner_access_mode)
    scope = get_field(changeset, :scope) || []

    case RunnerAccess.from_selection(mode, scope, runners) do
      {:ok, access} ->
        changeset
        |> put_change(:scope, RunnerAccess.selection_values(access.groups, access.runner_ids))
        |> put_change(:runner_access, access)

      {:error, :invalid_runner_access} ->
        add_error(changeset, :runner_access_mode, "requires at least one runner group or runner")
    end
  end
end
