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
  `scim_patch_group` own that.

  The SCIM resource `id` is the server-issued `DirectoryGroup.id`;
  `externalId` remains the IdP-owned create/filter correlation value.
  """
  use EmisarWeb, :controller
  alias Emisar.SSO
  alias EmisarWeb.SCIM.{Resource, Response}

  plug EmisarWeb.SCIM.Auth
  @max_group_member_ids 5_000

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

      if blank?(attrs.external_id) and blank?(attrs.display) do
        bad_request(conn, "invalidValue", "A SCIM Group requires an externalId or displayName.")
      else
        case SSO.scim_upsert_group(provider, attrs) do
          {:ok, summary} -> render_group(conn, :created, summary)
          {:error, reason} -> render_error(conn, reason)
        end
      end
    end
  end

  # PUT /scim/v2/Groups/:id — full replace of the addressed resource. A body
  # `id` or `externalId` never redirects the path mutation.
  def replace(conn, %{"id" => id} = params) do
    provider = conn.assigns.scim_provider

    if invalid_members?(Map.get(params, "members")) do
      render_error(conn, :invalid_scim_group)
    else
      attrs = Resource.parse_group(params)

      case SSO.scim_replace_group(provider, id, attrs) do
        {:ok, summary} -> render_group(conn, :ok, summary)
        {:error, reason} -> render_error(conn, reason)
      end
    end
  end

  # PATCH /scim/v2/Groups/:id — RFC 7644 §3.5.2 Operations.
  # `SSO.scim_patch_group/3` reduces the ordered batch — renames, whole-set
  # member replaces, member deltas — and applies it as one transition; this
  # action only judges the envelope's shape and renders the answer.
  def update(conn, %{"id" => id, "Operations" => operations})
      when is_list(operations) do
    case SSO.scim_patch_group(conn.assigns.scim_provider, id, operations) do
      {:ok, group} -> render_group(conn, :ok, group)
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def update(conn, %{"Operations" => _}),
    do: bad_request(conn, "invalidValue", "PATCH `Operations` must be a list.")

  def update(conn, _params),
    do: bad_request(conn, "invalidSyntax", "PATCH requires a SCIM PatchOp with `Operations`.")

  # DELETE /scim/v2/Groups/:id — emptying the group's membership + recomputing
  # the affected members' roles (a group delete is "nobody is in it anymore").
  # 204 No Content; the upsert always succeeds (see the moduledoc).
  def delete(conn, %{"id" => id}) do
    case SSO.scim_delete_group(conn.assigns.scim_provider, id) do
      {:ok, _summary} -> send_resp(conn, :no_content, "")
      {:error, :not_found} -> not_found(conn, id)
      {:error, reason} -> render_error(conn, reason)
    end
  end

  # GET /scim/v2/Groups/:id — echo the synced group so an IdP's read-back
  # round-trips by the service-provider-issued id.
  def show(conn, %{"id" => id}) do
    provider = conn.assigns.scim_provider

    case SSO.scim_fetch_group(provider, id) do
      {:ok, group} -> json(conn, Resource.to_group(group, group.member_ids))
      {:error, :not_found} -> not_found(conn, id)
    end
  end

  # GET /scim/v2/Groups — the provider's synced groups. `filter` carries the
  # `displayName eq "..."` probe Entra makes and the `externalId eq "..."`
  # probe Okta makes before later pushes; answering them is what stops the IdP
  # re-creating or erroring a group it already synced.
  # A present filter we cannot honor is declined instead of silently returning
  # the whole directory and letting an existence probe mistake any result for a
  # match.
  def index(conn, params) do
    provider = conn.assigns.scim_provider

    case group_filter(Map.get(params, "filter")) do
      :unsupported ->
        bad_request(
          conn,
          "invalidFilter",
          ~s(Only `displayName eq "..."` and `externalId eq "..."` filters are supported.)
        )

      opts ->
        case Resource.parse_pagination(params) do
          {:ok, page} ->
            {:ok, groups, total_results} =
              SSO.scim_list_groups(
                provider,
                opts ++ [offset: page.start_index - 1, limit: page.count]
              )

            resources = Enum.map(groups, &Resource.to_group(&1, &1.member_ids))
            json(conn, Resource.list_response(resources, total_results, page.start_index))

          {:error, :invalid_pagination} ->
            bad_request(
              conn,
              "invalidValue",
              "SCIM `startIndex` and `count` must be base-10 integers."
            )
        end
    end
  end

  defp group_filter(nil), do: []

  defp group_filter(filter) when is_binary(filter) do
    case Regex.run(~r/^\s*(displayName|externalId)\s+eq\s+"([^"]*)"\s*$/i, filter) do
      [_, attribute, value] -> group_filter_option(attribute, value)
      _ -> unquoted_group_filter(filter)
    end
  end

  defp group_filter(_filter), do: :unsupported

  defp unquoted_group_filter(filter) do
    case Regex.run(~r/^\s*(displayName|externalId)\s+eq\s+([^\s"]+)\s*$/i, filter) do
      [_, attribute, value] -> group_filter_option(attribute, value)
      _ -> :unsupported
    end
  end

  defp group_filter_option(attribute, value) do
    case String.downcase(attribute) do
      "displayname" -> [display_name: value]
      "externalid" -> [external_id: value]
    end
  end

  defp oversized_members?(members) when is_list(members),
    do: length(members) > @max_group_member_ids

  defp oversized_members?(_members), do: false

  defp invalid_members?(members),
    do: oversized_members?(members) or not Resource.valid_members?(members)

  # -- rendering ------------------------------------------------------

  defp render_group(conn, status, summary) do
    resource = Resource.to_group(summary, summary.member_ids)

    if status == :created do
      Response.created(conn, :group, summary.id, resource)
    else
      conn
      |> put_status(status)
      |> json(resource)
    end
  end

  defp render_error(conn, :invalid_scim_group),
    do: bad_request(conn, "invalidValue", "The SCIM Group payload was rejected.")

  defp render_error(conn, :not_found), do: not_found(conn, nil)

  defp render_error(conn, :directory_sync_disabled), do: Response.revoked(conn)

  defp render_error(conn, :unsupported_scim_patch), do: unsupported_patch(conn)

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
        "Only `displayName` replace and `members` add/remove/replace are supported on a Group."
    )
  end

  defp bad_request(conn, scim_type, detail) do
    conn
    |> put_status(:bad_request)
    |> json(Resource.error(400, scim_type, detail))
  end

  defp blank?(value), do: is_nil(value) or value == ""
end
