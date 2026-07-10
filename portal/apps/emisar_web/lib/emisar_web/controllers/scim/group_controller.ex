defmodule EmisarWeb.SCIM.GroupController do
  @moduledoc """
  Inbound SCIM 2.0 `/Groups` — the directory-group sync an IdP (Okta, Entra,
  Google) pushes so a member's emisar role tracks their IdP group membership.
  Every action reads the provider resolved by `SCIM.Auth` from
  `conn.assigns.scim_provider` and drives the account-scoped `Emisar.SSO.scim_*`
  group functions with it — the token's provider-scope IS the authorization
  (IL-15: re-read on every action, never trust the connection).

  The group→role *mapping* (which IdP group means which role) is configured by
  an operator on the SSO settings page; this endpoint only syncs the group's
  membership. A pushed group whose externalId has no mapping is still tracked
  (so a later-added mapping recomputes correctly) — `scim_upsert_group` /
  `scim_patch_group_members` own that.

  The SCIM resource `id` is the IdP's externalId (see `SCIM.Resource.to_group/1`),
  so `:id` here is the externalId the domain keys on. The domain has no SCIM
  group *read* (it tracks membership, not a queryable Group resource), so `GET`
  returns the minimal valid SCIM shape rather than a 500 (see those actions).
  """
  use EmisarWeb, :controller
  alias Emisar.SSO
  alias EmisarWeb.SCIM.Resource

  plug EmisarWeb.SCIM.Auth
  @max_group_member_ids 5_000
  @max_patch_operations 100

  # POST /scim/v2/Groups — provision (or reconcile) a group's membership.
  # `scim_upsert_group` recomputes affected members' roles best-effort: a
  # per-member recompute the last-owner guard refuses is held, not an HTTP
  # failure, while malformed SCIM group input is rejected as invalidValue.
  def create(conn, params) do
    provider = conn.assigns.scim_provider

    if invalid_members?(Map.get(params, "members")) do
      render_error(conn, :invalid_scim_group)
    else
      attrs = Resource.parse_group(params)

      if blank?(attrs.external_id) do
        bad_request(conn, "invalidValue", "A SCIM Group requires a displayName/externalId.")
      else
        case SSO.scim_upsert_group(provider, attrs) do
          {:ok, summary} -> render_group(conn, :created, summary, attrs.member_external_ids)
          {:error, reason} -> render_error(conn, reason)
        end
      end
    end
  end

  # PUT /scim/v2/Groups/:id — full replace of the group's membership. The path
  # id is the externalId the domain keys on (parse falls back to it).
  def replace(conn, %{"id" => external_id} = params) do
    provider = conn.assigns.scim_provider
    params = Map.put_new(params, "externalId", external_id)

    if invalid_members?(Map.get(params, "members")) do
      render_error(conn, :invalid_scim_group)
    else
      attrs = Resource.parse_group(params)

      case SSO.scim_upsert_group(provider, attrs) do
        {:ok, summary} -> render_group(conn, :ok, summary, attrs.member_external_ids)
        {:error, reason} -> render_error(conn, reason)
      end
    end
  end

  # PATCH /scim/v2/Groups/:id — RFC 7644 §3.5.2 Operations on `members`. We honor
  # add / remove (the membership delta IdPs push) and a whole-set `replace`; any
  # other op/path is an honest SCIM error, never a silent no-op.
  def update(conn, %{"id" => external_id, "Operations" => operations})
      when is_list(operations) do
    provider = conn.assigns.scim_provider

    case member_ops(operations) do
      {:replace, member_external_ids} ->
        attrs = %{
          external_id: external_id,
          display: nil,
          member_external_ids: member_external_ids
        }

        case SSO.scim_upsert_group(provider, attrs) do
          {:ok, summary} -> render_group(conn, :ok, summary, member_external_ids)
          {:error, reason} -> render_error(conn, reason)
        end

      {:delta, add_ids, remove_ids} ->
        case SSO.scim_patch_group_members(provider, external_id, add_ids, remove_ids) do
          {:ok, _summary} -> render_group(conn, :ok, %{external_group_id: external_id}, add_ids)
          {:error, reason} -> render_error(conn, reason)
        end

      {:error, reason} ->
        render_error(conn, reason)

      :unsupported ->
        unsupported_patch(conn)
    end
  end

  def update(conn, %{"Operations" => _}),
    do: bad_request(conn, "invalidValue", "PATCH `Operations` must be a list.")

  def update(conn, _params),
    do: bad_request(conn, "invalidSyntax", "PATCH requires a SCIM PatchOp with `Operations`.")

  # DELETE /scim/v2/Groups/:id — emptying the group's membership + recomputing
  # the affected members' roles (a group delete is "nobody is in it anymore").
  # 204 No Content; the upsert always succeeds (see the moduledoc).
  def delete(conn, %{"id" => external_id}) do
    provider = conn.assigns.scim_provider
    attrs = %{external_id: external_id, display: nil, member_external_ids: []}

    case SSO.scim_upsert_group(provider, attrs) do
      {:ok, _summary} -> send_resp(conn, :no_content, "")
      {:error, reason} -> render_error(conn, reason)
    end
  end

  # GET /scim/v2/Groups/:id — the domain tracks group membership but exposes no
  # SCIM Group read, so there's no resource to return. A 404 is the honest SCIM
  # answer (and what an IdP tolerates on a probe) — never a 500. DOMAIN GAP: a
  # group read (display + current member externalIds) would let this echo the
  # resource; out of Slice-2b scope (sync is push-only).
  def show(conn, %{"id" => external_id}) do
    not_found(conn, external_id)
  end

  # GET /scim/v2/Groups — same gap: no group read, so the minimal valid SCIM
  # ListResponse (empty) rather than a crash. IdPs probe this before pushing and
  # tolerate an empty list.
  def index(conn, _params) do
    json(conn, Resource.list_response([]))
  end

  # -- PATCH parsing (RFC 7644 §3.5.2, the `members` ops) --------------

  # Reduce the operation list to one of:
  #   {:replace, ids}        — a whole-set `members` replace (route to upsert),
  #   {:delta, adds, removes}— add/remove member deltas (route to patch),
  #   :unsupported           — any op we don't model (→ honest SCIM error).
  # A `replace` of the whole members set can't be combined with deltas in one
  # PatchOp (IdPs never do), so a replace wins and short-circuits.
  defp member_ops(operations) when length(operations) > @max_patch_operations,
    do: {:error, :invalid_scim_group}

  defp member_ops(operations) do
    Enum.reduce_while(operations, {:delta, [], [], 0}, fn op, acc ->
      case classify_op(op) do
        {:replace, ids} -> {:halt, {:replace, ids}}
        {:add, ids} -> merge_delta(acc, ids, [])
        {:remove, ids} -> merge_delta(acc, [], ids)
        {:error, reason} -> {:halt, {:error, reason}}
        :unsupported -> {:halt, :unsupported}
      end
    end)
    |> case do
      {:delta, [], [], _count} -> :unsupported
      {:delta, adds, removes, _count} -> {:delta, Enum.reverse(adds), Enum.reverse(removes)}
      result -> result
    end
  end

  defp merge_delta({:delta, adds, removes, count}, new_adds, new_removes) do
    count = count + length(new_adds) + length(new_removes)

    if count > @max_group_member_ids do
      {:halt, {:error, :invalid_scim_group}}
    else
      {:cont, {:delta, prepend_all(new_adds, adds), prepend_all(new_removes, removes), count}}
    end
  end

  defp prepend_all(values, acc), do: Enum.reduce(values, acc, &[&1 | &2])

  # `op` is case-insensitive ("add"/"Add"/"replace"/"remove"). We only model the
  # `members` attribute; an op on any other path (displayName, a sub-attribute)
  # is unsupported. A remove can carry the ids in `value` OR in a filtered path
  # (`members[value eq "x"]`, Okta's single-member removal).
  defp classify_op(%{} = op),
    do: classify_member_op(downcase(Map.get(op, "op")), Map.get(op, "path"), Map.get(op, "value"))

  defp classify_op(_op), do: :unsupported

  defp classify_member_op("add", path, value) do
    if members_path?(path), do: member_op(:add, value), else: :unsupported
  end

  defp classify_member_op("replace", path, value) do
    if members_path?(path), do: member_op(:replace, value), else: :unsupported
  end

  defp classify_member_op("remove", path, value) do
    filtered_remove = filtered_member_remove(path)

    cond do
      members_path?(path) -> member_op(:remove, value)
      filtered_remove != :skip -> filtered_remove
      true -> :unsupported
    end
  end

  defp classify_member_op(_verb, _path, _value), do: :unsupported

  defp member_op(kind, value) do
    if invalid_members?(value),
      do: {:error, :invalid_scim_group},
      else: {kind, Resource.parse_members(value)}
  end

  # path "members" (or absent — a pathless members op carries the array in value).
  defp members_path?(nil), do: true
  defp members_path?(path) when is_binary(path), do: downcase(path) == "members"
  defp members_path?(_), do: false

  # Okta removes a single member with `path: members[value eq "<externalId>"]`
  # and no value. Extract the quoted externalId; anything richer is unsupported.
  defp filtered_member_remove(path) when is_binary(path) do
    case Regex.run(~r/^members\[\s*value\s+eq\s+"([^"]+)"\s*\]$/i, path) do
      [_, external_id] -> {:remove, [external_id]}
      _ -> :skip
    end
  end

  defp filtered_member_remove(_path), do: :skip

  defp oversized_members?(members) when is_list(members),
    do: length(members) > @max_group_member_ids

  defp oversized_members?(_members), do: false

  defp invalid_members?(members),
    do: oversized_members?(members) or not Resource.valid_members?(members)

  defp downcase(value) when is_binary(value), do: String.downcase(value)
  defp downcase(_value), do: ""

  # -- rendering ------------------------------------------------------

  defp render_group(conn, status, summary, member_external_ids) do
    conn
    |> put_status(status)
    |> json(Resource.to_group(summary, member_external_ids))
  end

  defp render_error(conn, :invalid_scim_group),
    do: bad_request(conn, "invalidValue", "The SCIM Group payload was rejected.")

  defp render_error(conn, _reason),
    do: bad_request(conn, "invalidValue", "The SCIM Group request could not be processed.")

  defp not_found(conn, external_id) do
    detail =
      if external_id,
        do: "No SCIM Group with id `#{external_id}` in this directory.",
        else: "No matching SCIM Group in this directory."

    conn
    |> put_status(:not_found)
    |> json(Resource.error(404, detail))
  end

  defp unsupported_patch(conn) do
    bad_request(
      conn,
      "invalidPath",
      "This PATCH targets an attribute the directory connection does not support. " <>
        "Only `members` add/remove/replace is patchable on a Group."
    )
  end

  defp bad_request(conn, scim_type, detail) do
    conn
    |> put_status(:bad_request)
    |> json(Resource.error(400, scim_type, detail))
  end

  defp blank?(value), do: is_nil(value) or value == ""
end
