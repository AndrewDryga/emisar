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
  alias Emisar.Accounts.AccessSelection

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
    |> normalize_owner_access()
    |> then(&AccessSelection.validate(&1, allowlist, get_field(&1, :role)))
  end

  # Read at runtime: pinning these into a module attribute would make this input
  # schema a COMPILE dependency of Auth, closing a cycle back through Accounts.
  defp roles, do: Enum.map(Emisar.Auth.roles(), &Atom.to_string/1)

  defp normalize_owner_access(changeset) do
    if get_field(changeset, :role) == "owner" do
      changeset
      |> put_change(:runner_access_mode, "all")
      |> put_change(:scope, [])
      |> put_change(:pack_access_mode, "all")
      |> put_change(:pack_scope, [])
    else
      changeset
    end
  end
end
