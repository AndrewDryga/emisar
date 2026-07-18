defmodule Emisar.ApiKeys.DeviceGrant.Query do
  use Emisar, :query
  alias Emisar.ApiKeys.DeviceGrant

  def all, do: from(g in DeviceGrant, as: :device_grants)

  def by_device_code_digest(queryable \\ all(), digest),
    do: where(queryable, [device_grants: g], g.device_code_digest == ^digest)

  def by_user_code_digest(queryable \\ all(), digest),
    do: where(queryable, [device_grants: g], g.user_code_digest == ^digest)

  def by_status(queryable \\ all(), status),
    do: where(queryable, [device_grants: g], g.status == ^status)

  def not_expired(queryable \\ all(), now),
    do: where(queryable, [device_grants: g], g.expires_at > ^now)

  def expired_before(queryable \\ all(), now),
    do: where(queryable, [device_grants: g], g.expires_at <= ^now)

  # Grants live minutes; retention deletes by age regardless of status — a
  # pending row this old is long expired.
  def older_than(queryable \\ all(), cutoff),
    do: where(queryable, [device_grants: g], g.inserted_at < ^cutoff)

  # Lock the matched row FOR UPDATE so a concurrent approve/claim of the same
  # grant serializes: the first transitions it and commits, the second blocks,
  # re-reads the new status, and is rejected. Single-use delivery is the
  # security property; without the lock both could pass the status check.
  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end
