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

  # PATCH /scim/v2/Groups/:id — RFC 7644 §3.5.2 Operations.
  # `SSO.scim_patch_group/3` reduces the ordered batch — renames, whole-set
  # member replaces, member deltas — and applies it as one transition; this
  # action only judges the envelope's shape and renders the answer.
  def update(conn, %{"id" => external_id, "Operations" => operations})
      when is_list(operations) do
    case SSO.scim_patch_group(conn.assigns.scim_provider, external_id, operations) do
      {:ok, group} -> render_group(conn, :ok, group, group.member_external_ids)
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

    case Resource.parse_pagination(params) do
      {:ok, page} ->
        {:ok, groups, total_results} =
          SSO.scim_list_groups(
            provider,
            opts ++ [offset: page.start_index - 1, limit: page.count]
          )

        resources = Enum.map(groups, &Resource.to_group(&1, &1.member_external_ids))
        json(conn, Resource.list_response(resources, total_results, page.start_index))

      {:error, :invalid_pagination} ->
        bad_request(
          conn,
          "invalidValue",
          "SCIM `startIndex` and `count` must be base-10 integers."
        )
    end
  end

  # `displayName eq "Platform Engineers"` — the only Group filter IdPs send.
  defp display_name_filter(%{"filter" => filter}) when is_binary(filter) do
    case Regex.run(~r/^\s*displayName\s+eq\s+"(.*)"\s*$/i, filter) do
      [_, value] -> [display_name: value]
      _ -> []
    end
  end

  defp display_name_filter(_params), do: []

  defp oversized_members?(members) when is_list(members),
    do: length(members) > @max_group_member_ids

  defp oversized_members?(_members), do: false

  defp invalid_members?(members),
    do: oversized_members?(members) or not Resource.valid_members?(members)

  # -- rendering ------------------------------------------------------

  defp render_group(conn, status, summary, member_external_ids) do
    conn
    |> put_status(status)
    |> json(Resource.to_group(summary, member_external_ids))
  end

  defp render_error(conn, :invalid_scim_group),
    do: bad_request(conn, "invalidValue", "The SCIM Group payload was rejected.")

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
