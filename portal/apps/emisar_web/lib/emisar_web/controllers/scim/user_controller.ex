defmodule EmisarWeb.SCIM.UserController do
  @moduledoc """
  Inbound SCIM 2.0 `/Users` — the directory-sync lifecycle an IdP (Okta,
  Entra, Google) pushes: create/reconcile, read, list/filter, the `active`
  flip (PATCH/PUT), and DELETE. Every action reads the provider resolved by
  `SCIM.Auth` from `conn.assigns.scim_provider` and drives the account-scoped
  `Emisar.SSO.scim_*` functions with it — the token's provider-scope IS the
  authorization (IL-15: re-read on every action, never trust the connection).

  The SCIM resource `id` is the server-issued `UserIdentity.id`; `externalId`
  remains the IdP-owned create/filter correlation value. Every mutation resolves to
  one typed `SSO.SCIMUserUpdate` the domain commits atomically — PATCH hands
  its raw operation list to `SSO.scim_patch_user/3`, which owns the RFC 7644
  §3.5.2 reduction; PUT states the desired update directly. DELETE suspends the
  internal membership and retires the wire resource, preserving the person for
  an explicit later create. This controller decodes the wire envelope and renders.
  """
  use EmisarWeb, :controller
  alias Emisar.SSO
  alias EmisarWeb.SCIM.{Resource, Response}

  plug EmisarWeb.SCIM.Auth

  # POST /scim/v2/Users — provision (or reconcile, idempotently).
  def create(conn, params) do
    provider = conn.assigns.scim_provider
    attrs = Resource.parse_user(params)

    cond do
      blank?(attrs.external_id) ->
        bad_request(conn, "invalidValue", "A SCIM User requires an externalId or userName.")

      not is_boolean(attrs.active) ->
        bad_request(conn, "invalidValue", "A SCIM User `active` value must be boolean.")

      true ->
        case SSO.scim_provision_user(provider, attrs) do
          {:ok, %{identity: identity}} -> render_current(conn, :created, identity.id)
          {:error, reason} -> render_error(conn, reason)
        end
    end
  end

  # GET /scim/v2/Users/:id — fetch one by server-issued resource id.
  def show(conn, %{"id" => id}), do: render_current(conn, :ok, id)

  # GET /scim/v2/Users — list, optionally filtered by `userName eq "x"` /
  # `externalId eq "x"`. The filter is applied in the query (not in memory over
  # the fetched page), so an IdP's existence probe finds the user wherever they
  # are in the directory. ABSENT filter → list all. A PRESENT filter we can't
  # honor → 400 invalidFilter, NOT list-all: returning the whole directory would
  # let an IdP's existence probe misread "got results" as "this user exists"
  # (RFC 7644 §3.4.2.2 / §3.12 permit declining a filter with invalidFilter).
  def index(conn, params) do
    provider = conn.assigns.scim_provider

    case parse_filter(Map.get(params, "filter")) do
      :unsupported ->
        bad_request(
          conn,
          "invalidFilter",
          ~s(Only `userName eq "..."` or `externalId eq "..."` filters are supported.)
        )

      scim_filter ->
        case Resource.parse_pagination(params) do
          {:ok, page} ->
            {:ok, scim_users, total_results} =
              SSO.scim_list_users(provider,
                scim_filter: scim_filter,
                offset: page.start_index - 1,
                limit: page.count
              )

            resources = Enum.map(scim_users, &Resource.to_user/1)
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

  # PATCH /scim/v2/Users/:id — RFC 7644 §3.5.2 Operations. `SSO.scim_patch_user/3`
  # reduces the ordered batch into one desired state and applies it; this action
  # only judges the envelope's shape and renders the answer.
  def update(conn, %{"id" => id, "Operations" => operations})
      when is_list(operations) do
    case SSO.scim_patch_user(conn.assigns.scim_provider, id, operations) do
      {:ok, _result} -> render_current(conn, :ok, id)
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def update(conn, %{"Operations" => _}),
    do: bad_request(conn, "invalidValue", "PATCH `Operations` must be a list.")

  def update(conn, _params),
    do: bad_request(conn, "invalidSyntax", "PATCH requires a SCIM PatchOp with `Operations`.")

  # PUT /scim/v2/Users/:id — full replace. Acts on the IdP-owned attributes:
  # `displayName` (the synced profile name) and the `active` lifecycle flag;
  # everything else (email, externalId) stays immutable post-provision here.
  def replace(conn, %{"id" => id} = params) do
    attrs = Resource.parse_user(params)

    case Resource.parse_active(Map.get(params, "active"), nil) do
      nil ->
        bad_request(conn, "invalidValue", "PUT requires a boolean `active`.")

      active ->
        apply_update(conn, id, %SSO.SCIMUserUpdate{
          name: put_name(attrs.full_name),
          active: active
        })
    end
  end

  defp put_name(nil), do: :keep
  defp put_name(full_name), do: {:replace, full_name}

  # The write behind PUT: the domain commits everything the request asked for —
  # rename and lifecycle — or nothing.
  defp apply_update(conn, id, %SSO.SCIMUserUpdate{} = update) do
    case SSO.scim_update_user(conn.assigns.scim_provider, id, update) do
      {:ok, _result} -> render_current(conn, :ok, id)
      {:error, reason} -> render_error(conn, reason)
    end
  end

  # DELETE /scim/v2/Users/:id — suspend access and retire the wire resource.
  # The internal person/history survives; later operations on this id return 404.
  def delete(conn, %{"id" => id}) do
    provider = conn.assigns.scim_provider

    case SSO.scim_delete_user(provider, id) do
      {:ok, _result} -> send_resp(conn, :no_content, "")
      {:error, reason} -> render_error(conn, reason)
    end
  end

  # -- filter parsing (RFC 7644 §3.4.2.2, the `attr eq "value"` subset) --

  # Parse the SCIM filter string into the domain filter `SSO.scim_list_users/2`
  # applies in the query. `userName`/`externalId eq` are the existence-probe
  # filters IdPs send before a create; matching `attr eq "value"` (and the
  # unquoted form), case-insensitive on the attribute. ABSENT → nil (list all);
  # anything richer (and/or, co, sw, …) or an attribute we don't index →
  # :unsupported, so index/2 declines with 400 invalidFilter rather than
  # silently listing the whole directory.
  defp parse_filter(nil), do: nil

  defp parse_filter(filter) when is_binary(filter) do
    case Regex.run(~r/^\s*(\w+)\s+eq\s+"?([^"]*)"?\s*$/i, filter) do
      [_, attr, value] -> filter_for(String.downcase(attr), value)
      _ -> :unsupported
    end
  end

  defp parse_filter(_filter), do: nil

  defp filter_for("username", value), do: {:user_name, value}
  defp filter_for("externalid", value), do: {:external_id, value}
  defp filter_for(_attr, _value), do: :unsupported

  # -- rendering ------------------------------------------------------

  # Every User response body — a GET's as much as a mutation's — renders from
  # the one projection read, so a mutation's answer can never drift from the
  # next read's. Rendering mutation results directly is how a response once
  # reported `active: true` for someone a manual hold keeps signed out.
  defp render_current(conn, status, id) do
    case SSO.scim_fetch_user(conn.assigns.scim_provider, id) do
      {:ok, scim_user} ->
        resource = Resource.to_user(scim_user)

        if status == :created do
          Response.created(conn, :user, id, resource)
        else
          conn
          |> put_status(status)
          |> json(resource)
        end

      {:error, :not_found} ->
        not_found(conn, id)
    end
  end

  defp render_error(conn, :not_found), do: not_found(conn, nil)

  # Authentication can succeed, then an operator can disable or delete the
  # connection before the mutation takes its provider-row fence. That is a
  # revoked bearer at execution time, not a malformed payload.
  defp render_error(conn, :directory_sync_disabled) do
    conn
    |> put_resp_header("www-authenticate", "Bearer")
    |> put_status(:unauthorized)
    |> json(
      Resource.error(401, "The SCIM bearer token is missing, malformed, or not authorized.")
    )
  end

  defp render_error(conn, :last_owner) do
    conn
    |> put_status(:conflict)
    |> json(
      Resource.error(
        409,
        "mutability",
        "Cannot deprovision the last active owner of the account."
      )
    )
  end

  # The email uniqueness this reports is GLOBAL, not per-account, so saying "in
  # the account" told an account's bearer something false about an address that
  # may belong to a workspace it cannot see. The 409 itself is unavoidable — the
  # write genuinely cannot proceed and the directory has to be told — but it says
  # only that the address is unavailable, and says the same whether the person is
  # a member here or a stranger elsewhere.
  # The connection already has an identity under this identifier, bound to
  # someone else. There is no row this create can honestly occupy.
  defp render_error(conn, :identifier_taken) do
    conn
    |> put_status(:conflict)
    |> json(Resource.error(409, "uniqueness", "That externalId is already in use."))
  end

  defp render_error(conn, :email_taken) do
    conn
    |> put_status(:conflict)
    |> json(Resource.error(409, "uniqueness", "That email address is not available."))
  end

  defp render_error(conn, :too_many_scim_operations),
    do: bad_request(conn, "tooMany", "PATCH carries too many operations.")

  defp render_error(conn, :invalid_scim_active),
    do: bad_request(conn, "invalidValue", "Unparseable PATCH `active` value.")

  defp render_error(conn, :unsupported_scim_patch), do: unsupported_patch(conn)

  defp render_error(conn, %Ecto.Changeset{}),
    do: bad_request(conn, "invalidValue", "The SCIM User payload was rejected.")

  defp render_error(conn, _reason),
    do: bad_request(conn, "invalidValue", "The SCIM request could not be processed.")

  defp not_found(conn, external_id) do
    detail =
      if external_id,
        do: "No SCIM User with id `#{external_id}` in this directory.",
        else: "No matching SCIM User in this directory."

    conn
    |> put_status(:not_found)
    |> json(Resource.error(404, detail))
  end

  defp unsupported_patch(conn) do
    bad_request(
      conn,
      "invalidPath",
      "This PATCH targets an attribute the directory connection does not support. " <>
        "Only the `active` flag is patchable."
    )
  end

  defp bad_request(conn, scim_type, detail) do
    conn
    |> put_status(:bad_request)
    |> json(Resource.error(400, scim_type, detail))
  end

  defp blank?(value), do: is_nil(value) or value == ""
end
