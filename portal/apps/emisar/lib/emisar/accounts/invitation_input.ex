defmodule Emisar.Accounts.InvitationInput do
  @moduledoc """
  One invitation submission — the invitee's address, the role being granted, and
  the reach that comes with it (which runners, and which packs on them). Never
  persisted: `Accounts` casts the raw form params through it, so the browser form
  and the write share ONE definition of a valid invitation and a crafted role,
  runner, or pack selector is a field error at the context boundary instead of a
  widened grant.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Emisar.Accounts.RunnerAccess

  @primary_key false
  embedded_schema do
    field :email, :string
    # The role and modes travel as strings because that is what the browser
    # posts; `Membership.role` itself is the canonical atom enum.
    field :role, :string, default: "operator"
    field :runner_access_mode, :string, default: "none"
    field :scope, {:array, :string}, default: []
    field :pack_access_mode, :string, default: "all"
    field :pack_scope, {:array, :string}, default: []

    # The canonical access the validated selection resolved to.
    field :runner_access, :any, virtual: true
  end

  @fields ~w[email role runner_access_mode scope pack_access_mode pack_scope]a

  @doc """
  Casts one invitation submission against `allowlist` — the account's current
  `%{groups: _, runners: _, packs: _}` facts the selection is allowlisted
  against.

  A valid changeset carries the trimmed email, the granted role, and the
  canonical `%RunnerAccess{}` in `:runner_access`, with `:scope`/`:pack_scope`
  normalized to the selectors that survived (a runner a chosen group already
  covers is dropped). An empty selected-runner scope is a `:runner_access_mode`
  error; an empty or unknown pack selection is a `:pack_access_mode` error.
  """
  def changeset(attrs, allowlist) do
    %__MODULE__{}
    |> cast(attrs, @fields)
    |> update_change(:email, &String.trim/1)
    |> validate_required([:email])
    |> Emisar.EmailAddress.validate(:email)
    |> validate_inclusion(:role, roles())
    |> validate_inclusion(:runner_access_mode, modes())
    |> validate_inclusion(:pack_access_mode, pack_modes())
    |> validate_runner_access(allowlist)
  end

  # Read at runtime: pinning these into module attributes would make this input
  # schema a COMPILE dependency of Auth, closing a cycle back through Accounts.
  defp roles, do: Enum.map(Emisar.Auth.roles(), &Atom.to_string/1)
  defp modes, do: Enum.map(RunnerAccess.modes(), &Atom.to_string/1)
  defp pack_modes, do: Enum.map(RunnerAccess.pack_modes(), &Atom.to_string/1)

  defp validate_runner_access(%Ecto.Changeset{} = changeset, allowlist) do
    mode = get_field(changeset, :runner_access_mode)
    scope = get_field(changeset, :scope) || []
    pack_mode = get_field(changeset, :pack_access_mode)
    pack_scope = get_field(changeset, :pack_scope) || []

    case RunnerAccess.from_selection(mode, scope, allowlist, pack_mode, pack_scope) do
      {:ok, selected} ->
        # The role decides what the selection may actually grant, so an invite to
        # a role that carries no reach resets it here rather than at the write —
        # the form re-renders from `:runner_access` and shows the operator the
        # cleared state before they send it.
        access = RunnerAccess.for_role(get_field(changeset, :role), selected)

        changeset
        |> put_change(:scope, RunnerAccess.selection_values(access.groups, access.runner_ids))
        |> put_change(:pack_scope, RunnerAccess.pack_selection_values(access.pack_ids))
        |> put_change(:runner_access, access)
        |> put_change(:runner_access_mode, to_string(access.mode))
        |> put_change(:pack_access_mode, to_string(access.pack_mode))

      {:error, :invalid_pack_access} ->
        add_error(changeset, :pack_access_mode, "requires at least one available pack")

      {:error, :invalid_runner_access} ->
        add_error(changeset, :runner_access_mode, "requires at least one runner group or runner")
    end
  end
end
