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
  # id is the externalId the domain keys on, and it WINS: `put_new` let a body
  # `externalId` through, so `PUT /Groups/viewers` carrying `externalId:
  # "admins"` rewrote the admin group's membership instead of the one addressed.
  # A request now only ever mutates the resource it names in the path.
  def replace(conn, %{"id" => external_id} = params) do
    provider = conn.assigns.scim_provider
    params = Map.put(params, "externalId", external_id)

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

    # A batch may carry both a rename and membership changes. Recognizing a
    # rename only as the SOLE operation sent an otherwise valid
    # `replace displayName` + `add members` batch into the member fold, where the
    # rename classified as unsupported and the whole request 400'd.
    {renames, member_operations} =
      operations
      |> Enum.flat_map(&split_pathless_attributes/1)
      |> Enum.reject(&settles_external_id?(&1, external_id))
      |> Enum.split_with(&rename_op?/1)

    # Members first, then the rename. The display is a single scalar, so its
    # position in the batch cannot change the final state — but the name is
    # stamped onto the group's membership rows, and renaming before they exist
    # leaves a group the batch just populated with no name at all.
    patch_members(conn, provider, external_id, member_operations, renames)
  end

  def update(conn, %{"Operations" => _}),
    do: bad_request(conn, "invalidValue", "PATCH `Operations` must be a list.")

  def update(conn, _params),
    do: bad_request(conn, "invalidSyntax", "PATCH requires a SCIM PatchOp with `Operations`.")

  # SCIM's `id` is immutable and `displayName` is not, so the group keeps the id
  # we issued and the IdP keeps addressing it by that — only the display moves.
  # JumpCloud's activation sends exactly this and treats a 400 as a hard failure.
  # Wire order decides, so the last rename in the batch is the one that sticks.
  defp apply_renames(_provider, _external_id, []), do: :ok

  defp apply_renames(provider, external_id, renames) do
    display = renames |> List.last() |> rename_display()

    case SSO.scim_rename_group(provider, external_id, display) do
      {:ok, _summary} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Two shapes carry a rename: a pathless `replace` whose value map holds
  # displayName, and a `replace` with `path: "displayName"` and a bare string.
  # A pathless `replace` carries a MAP of attributes, and it may name more than
  # one. Treating any such map containing `displayName` as a rename dropped
  # `members` on the floor — the endpoint answered 200 while the people the
  # directory had just removed kept the group's mapped role and runner access.
  # Split it into one operation per attribute so each reaches its own handler.
  defp split_pathless_attributes(%{"value" => %{} = value} = op) do
    path = Map.get(op, "path")

    if replace?(op) and (is_nil(path) or path == "") and map_size(value) > 1 do
      Enum.map(value, fn {attribute, attribute_value} ->
        op |> Map.put("path", attribute) |> Map.put("value", attribute_value)
      end)
    else
      [op]
    end
  end

  defp split_pathless_attributes(op), do: [op]

  # Entra reads a group back after creating it and PATCHes `externalId` to the
  # value it expects. That value is our resource id, so the operation asks for
  # what is already true — but answering 400 stopped the group's sync dead and
  # left its role mapping permanently unapplied. A PATCH setting `externalId` to
  # THIS group's id is accepted as the no-op it is; one naming a different id is
  # left in place to be refused, because moving a resource is not something we do.
  defp settles_external_id?(op, external_id) do
    replace?(op) and external_id_path?(Map.get(op, "path")) and
      Map.get(op, "value") == external_id
  end

  defp external_id_path?(path) when is_binary(path), do: downcase(path) == "externalid"
  defp external_id_path?(_path), do: false

  defp rename_op?(op), do: rename_display(op) != nil

  defp renamed(summary, []), do: summary

  defp renamed(summary, renames),
    do: Map.put(summary, :display, renames |> List.last() |> rename_display())

  defp rename_display(%{"value" => %{"displayName" => display}} = op) when is_binary(display) do
    path = Map.get(op, "path")

    if replace?(op) and (is_nil(path) or path == ""), do: display, else: nil
  end

  defp rename_display(%{"path" => path, "value" => display} = op)
       when is_binary(path) and is_binary(display) do
    if replace?(op) and String.downcase(path) == "displayname", do: display, else: nil
  end

  defp rename_display(_op), do: nil

  defp replace?(op), do: downcase(Map.get(op, "op")) == "replace"

  # Nothing left to apply — the batch was only a rename, or only the externalId
  # no-op Entra sends. Answer with the group as it stands.
  defp patch_members(conn, provider, external_id, [], []) do
    case SSO.scim_fetch_group(provider, external_id) do
      {:ok, group} -> render_group(conn, :ok, group, group.member_external_ids)
      {:error, reason} -> render_error(conn, reason)
    end
  end

  # A batch of nothing but renames has no membership to reconcile.
  defp patch_members(conn, provider, external_id, [], renames) do
    case apply_renames(provider, external_id, renames) do
      :ok ->
        display = renames |> List.last() |> rename_display()
        render_group(conn, :ok, %{external_group_id: external_id, display: display}, [])

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  defp patch_members(conn, provider, external_id, operations, renames) do
    case member_ops(operations) do
      {:replace, member_external_ids} ->
        attrs = %{
          external_id: external_id,
          display: nil,
          member_external_ids: member_external_ids
        }

        with {:ok, summary} <- SSO.scim_upsert_group(provider, attrs),
             :ok <- apply_renames(provider, external_id, renames) do
          render_group(conn, :ok, renamed(summary, renames), member_external_ids)
        else
          {:error, reason} -> render_error(conn, reason)
        end

      {:delta, add_ids, remove_ids} ->
        with {:ok, _summary} <-
               SSO.scim_patch_group_members(provider, external_id, add_ids, remove_ids),
             :ok <- apply_renames(provider, external_id, renames) do
          summary = renamed(%{external_group_id: external_id}, renames)
          render_group(conn, :ok, summary, add_ids)
        else
          {:error, reason} -> render_error(conn, reason)
        end

      {:error, reason} ->
        render_error(conn, reason)

      :unsupported ->
        unsupported_patch(conn)
    end
  end

  # DELETE /scim/v2/Groups/:id — emptying the group's membership + recomputing
  # the affected members' roles (a group delete is "nobody is in it anymore").
  # 204 No Content; the upsert always succeeds (see the moduledoc).
  def delete(conn, %{"id" => external_id}) do
    case SSO.scim_delete_group(conn.assigns.scim_provider, external_id) do
      {:ok, _summary} -> send_resp(conn, :no_content, "")
      {:error, :not_found} -> not_found(conn, external_id)
      {:error, reason} -> render_error(conn, reason)
    end
  end

  # GET /scim/v2/Groups/:id — echo the synced group so an IdP's read-back
  # round-trips. The path id is the externalId the domain keys on.
  def show(conn, %{"id" => external_id}) do
    provider = conn.assigns.scim_provider

    case SSO.scim_fetch_group(provider, external_id) do
      {:ok, group} -> json(conn, Resource.to_group(group, group.member_external_ids))
      {:error, :not_found} -> not_found(conn, external_id)
    end
  end

  # GET /scim/v2/Groups — the provider's synced groups. `filter` carries the
  # `displayName eq "..."` probe Entra makes before every push; answering it is
  # what stops the IdP re-creating a group it already synced on every cycle.
  # An unparseable filter lists everything rather than erroring — a broad answer
  # still lets the IdP find its group, where a 400 fails the whole sync.
  def index(conn, params) do
    provider = conn.assigns.scim_provider
    opts = display_name_filter(params)

    groups =
      provider
      |> SSO.scim_list_groups(opts)
      |> Enum.map(&Resource.to_group(&1, &1.member_external_ids))

    json(conn, Resource.list_response(groups))
  end

  # `displayName eq "Platform Engineers"` — the only Group filter IdPs send.
  defp display_name_filter(%{"filter" => filter}) when is_binary(filter) do
    case Regex.run(~r/^\s*displayName\s+eq\s+"(.*)"\s*$/i, filter) do
      [_, value] -> [display_name: value]
      _ -> []
    end
  end

  defp display_name_filter(_params), do: []

  # -- PATCH parsing (RFC 7644 §3.5.2, the `members` ops) --------------

  # Reduce the operation list to one of:
  #   {:replace, ids}        — a whole-set `members` replace (route to upsert),
  #   {:delta, adds, removes}— add/remove member deltas (route to patch),
  #   :unsupported           — any op we don't model (→ honest SCIM error).
  #
  # RFC 7644 §3.5.2 applies operations IN ORDER, so the fold carries one running
  # state and the last op to mention a member decides whether it ends up in the
  # group. A whole-set `replace` supersedes everything BEFORE it and hands us the
  # absolute set, so an `add`/`remove` after one applies to that set directly —
  # no read needed. Short-circuiting on the first replace instead dropped every
  # later op: `replace members=[victim]` followed by `remove victim` — an IdP
  # rewriting a group and then offboarding in one request — left the victim in a
  # group that may map to an admin role or runner access.
  defp member_ops(operations) when length(operations) > @max_patch_operations,
    do: {:error, :invalid_scim_group}

  defp member_ops(operations) do
    Enum.reduce_while(operations, {:delta, [], [], 0}, fn op, acc ->
      case classify_op(op) do
        {:replace, ids} -> replaced(ids)
        {:add, ids} -> add_members(acc, ids)
        {:remove, ids} -> remove_members(acc, ids)
        {:error, reason} -> {:halt, {:error, reason}}
        :unsupported -> {:halt, :unsupported}
      end
    end)
    |> case do
      {:delta, [], [], _count} -> :unsupported
      {:delta, adds, removes, _count} -> {:delta, adds, removes}
      result -> result
    end
  end

  defp add_members({:replace, ids}, added), do: replaced(append(ids, added))

  defp add_members({:delta, adds, removes, count}, added),
    do: delta(append(adds, added), removes -- added, count + length(added))

  defp remove_members({:replace, ids}, removed), do: replaced(ids -- removed)

  defp remove_members({:delta, adds, removes, count}, removed),
    do: delta(adds -- removed, append(removes, removed), count + length(removed))

  # The id moves to the end of the list it belongs in, and leaves the other one.
  defp append(ids, changed), do: (ids -- changed) ++ changed

  defp replaced(ids) when length(ids) > @max_group_member_ids,
    do: {:halt, {:error, :invalid_scim_group}}

  defp replaced(ids), do: {:cont, {:replace, ids}}

  defp delta(_adds, _removes, count) when count > @max_group_member_ids,
    do: {:halt, {:error, :invalid_scim_group}}

  defp delta(adds, removes, count), do: {:cont, {:delta, adds, removes, count}}

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
