defmodule Emisar.ApiKeys.DeviceGrant.Changeset do
  use Emisar, :changeset
  alias Emisar.ApiKeys.DeviceGrant

  @doc """
  Opens a pending grant from the unauthenticated installer request. Only
  `requested_clients` (and the transport-derived `requester_ip`) are cast —
  the codes arrive pre-digested and the expiry is server-set.
  """
  def create(device_code_digest, user_code_digest, attrs, expires_at) do
    %DeviceGrant{}
    |> cast(attrs, [:requested_clients, :requester_ip])
    |> update_change(:requested_clients, &Enum.uniq/1)
    |> put_change(:device_code_digest, device_code_digest)
    |> put_change(:user_code_digest, user_code_digest)
    |> put_change(:expires_at, expires_at)
    |> validate_required([:expires_at])
    |> validate_requested_clients_present()
    |> validate_length(:requested_clients, max: length(DeviceGrant.known_clients()))
    |> validate_subset(:requested_clients, DeviceGrant.known_clients())
    |> validate_length(:requester_ip, max: 64)
    |> unique_constraint(:device_code_digest)
    |> unique_constraint(:user_code_digest, name: :api_key_device_grants_pending_user_code_index)
  end

  @doc "Binds the approver — their recorded identity authorizes the claim-time mint."
  def approve(%DeviceGrant{} = grant, account_id, user_id, membership_id) do
    change(grant,
      status: :approved,
      account_id: account_id,
      approved_by_id: user_id,
      approved_by_membership_id: membership_id
    )
  end

  @doc "Records the denier for the audit trail; the poll reports access_denied."
  def deny(%DeviceGrant{} = grant, account_id, user_id, membership_id) do
    change(grant,
      status: :denied,
      account_id: account_id,
      approved_by_id: user_id,
      approved_by_membership_id: membership_id
    )
  end

  def claim(%DeviceGrant{} = grant), do: change(grant, status: :claimed)

  def expire(%DeviceGrant{} = grant), do: change(grant, status: :expired)

  # `[]` equals the column default, so it casts to "no change" and slips past
  # the change-based validators — check the FIELD, not the change.
  defp validate_requested_clients_present(changeset) do
    case get_field(changeset, :requested_clients) do
      [] -> add_error(changeset, :requested_clients, "can't be blank", validation: :required)
      _clients -> changeset
    end
  end
end
