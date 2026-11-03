defmodule Emisar.Accounts.ServiceAccountInput do
  @moduledoc """
  One add-service-account submission — the name, and the reach the service
  account starts with (which runners, and which packs on them). Never persisted:
  `Accounts` casts the raw form params through it, so the browser form and the
  write share ONE definition of a valid service account, and a crafted runner or
  pack selector is a field error at the context boundary instead of a widened
  grant.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Emisar.Accounts.AccessSelection

  @primary_key false
  embedded_schema do
    field :display_name, :string
    # The modes travel as strings because that is what the browser posts. The
    # defaults are the invite form's: no runners until the operator picks some.
    field :runner_access_mode, :string, default: "none"
    field :scope, {:array, :string}, default: []
    field :pack_access_mode, :string, default: "all"
    field :pack_scope, {:array, :string}, default: []

    # The canonical access the validated selection resolved to.
    field :runner_access, :any, virtual: true
  end

  @fields ~w[display_name runner_access_mode scope pack_access_mode pack_scope]a

  @doc """
  Casts one submission against `allowlist` — the account's current
  `%{groups: _, runners: _, packs: _}` facts the selection is allowlisted
  against.

  The name follows the rules the service account's membership row enforces. A
  valid changeset carries the canonical `%RunnerAccess{}` in `:runner_access`,
  resolved for the Operator role every service account holds; see
  `Emisar.Accounts.AccessSelection.validate/3` for the selection's errors.
  """
  def changeset(attrs, allowlist) do
    %__MODULE__{}
    |> cast(attrs, @fields)
    |> validate_required([:display_name])
    |> validate_length(:display_name, max: 255, count: :codepoints)
    |> AccessSelection.validate(allowlist, :operator)
  end
end
