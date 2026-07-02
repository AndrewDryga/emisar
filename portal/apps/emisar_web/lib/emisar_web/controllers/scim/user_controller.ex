defmodule EmisarWeb.SCIM.UserController do
  @moduledoc """
  Inbound SCIM 2.0 `/Users` — the directory-sync lifecycle an IdP (Okta,
  Entra, Google) pushes: create/reconcile, read, list/filter, the `active`
  flip (PATCH/PUT), and DELETE. Every action reads the provider resolved by
  `SCIM.Auth` from `conn.assigns.scim_provider` and drives the account-scoped
  `Emisar.SSO.scim_*` functions with it — the token's provider-scope IS the
  authorization (IL-15: re-read on every action, never trust the connection).

  The SCIM resource `id` is the IdP's externalId (see `SCIM.Resource.to_user/1`),
  so `:id` here is the externalId the domain keys on. Deprovisioning is a
  SUSPEND, never a delete: both `PATCH active:false` and `DELETE` map to
  `scim_deactivate_user`, `active:true` to `scim_reactivate_user` (R8).
  """
  use EmisarWeb, :controller
  alias Emisar.SSO
  alias EmisarWeb.SCIM.Resource

  plug EmisarWeb.SCIM.Auth

  # POST /scim/v2/Users — provision (or reconcile, idempotently).
  def create(conn, params) do
    provider = conn.assigns.scim_provider
    attrs = Resource.parse_user(params)

    if blank?(attrs.external_id) do
      bad_request(conn, "invalidValue", "A SCIM User requires an externalId or userName.")
    else
      case SSO.scim_provision_user(provider, attrs) do
        {:ok, result} -> render_user(conn, :created, result)
        {:error, reason} -> render_error(conn, reason)
      end
    end
  end

  # GET /scim/v2/Users/:id — fetch one by externalId.
  def show(conn, %{"id" => external_id}) do
    provider = conn.assigns.scim_provider

    case SSO.scim_fetch_user(provider, external_id) do
      {:ok, identity} -> render_user(conn, :ok, identity)
      {:error, :not_found} -> not_found(conn, external_id)
    end
  end

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
        case SSO.scim_list_users(provider, scim_filter: scim_filter, page: [limit: 100]) do
          {:ok, identities, _meta} ->
            json(conn, Resource.list_response(Enum.map(identities, &Resource.to_user/1)))

          {:error, _reason} ->
            json(conn, Resource.list_response([]))
        end
    end
  end

  # PATCH /scim/v2/Users/:id — RFC 7644 §3.5.2 Operations. Honors the `active`
  # replace (lifecycle) and the `displayName` replace (the IdP owns a synced
  # user's name); any other op is an honest SCIM error, never a silent no-op.
  def update(conn, %{"id" => external_id, "Operations" => operations})
      when is_list(operations) do
    case {name_from_operations(operations), active_from_operations(operations)} do
      {_name_op, :error} ->
        bad_request(conn, "invalidValue", "Unparseable PATCH `active` value.")

      {:no_name_op, :no_active_op} ->
        unsupported_patch(conn)

      {name_op, active_op} ->
        apply_operations(conn, external_id, name_op, active_op)
    end
  end

  def update(conn, %{"Operations" => _}),
    do: bad_request(conn, "invalidValue", "PATCH `Operations` must be a list.")

  def update(conn, _params),
    do: bad_request(conn, "invalidSyntax", "PATCH requires a SCIM PatchOp with `Operations`.")

  # PUT /scim/v2/Users/:id — full replace. Acts on the IdP-owned attributes:
  # `displayName` (the synced profile name) and the `active` lifecycle flag;
  # everything else (email, externalId) stays immutable post-provision here.
  def replace(conn, %{"id" => external_id} = params) do
    attrs = Resource.parse_user(params)

    case Resource.parse_active(Map.get(params, "active"), nil) do
      nil ->
        bad_request(conn, "invalidValue", "PUT requires a boolean `active`.")

      active ->
        apply_operations(conn, external_id, name_op(attrs.full_name), {:ok, active})
    end
  end

  defp name_op(nil), do: :no_name_op
  defp name_op(full_name), do: {:ok, full_name}

  # Apply the (optional) rename first, then the (optional) active flip — a
  # rename failure (e.g. :not_found) must not half-apply the lifecycle change.
  defp apply_operations(conn, external_id, name_op, active_op) do
    case apply_rename(conn, external_id, name_op) do
      :ok -> apply_operations_active(conn, external_id, active_op)
      {:error, reason} -> render_error(conn, reason)
    end
  end

  defp apply_rename(_conn, _external_id, :no_name_op), do: :ok

  defp apply_rename(conn, external_id, {:ok, full_name}) do
    case SSO.scim_rename_user(conn.assigns.scim_provider, external_id, full_name) do
      {:ok, _identity} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_operations_active(conn, external_id, {:ok, active}),
    do: apply_active(conn, external_id, active)

  # A name-only PATCH — render the (renamed) current resource state.
  defp apply_operations_active(conn, external_id, :no_active_op) do
    case SSO.scim_fetch_user(conn.assigns.scim_provider, external_id) do
      {:ok, identity} -> render_user(conn, :ok, identity)
      {:error, :not_found} -> not_found(conn, external_id)
    end
  end

  # DELETE /scim/v2/Users/:id — soft deprovision (suspend), not a hard delete
  # (R8 / decision 5). 204 No Content on success.
  def delete(conn, %{"id" => external_id}) do
    provider = conn.assigns.scim_provider

    case SSO.scim_deactivate_user(provider, external_id) do
      {:ok, _result} -> send_resp(conn, :no_content, "")
      {:error, reason} -> render_error(conn, reason)
    end
  end

  # -- active flip ----------------------------------------------------

  defp apply_active(conn, external_id, false) do
    provider = conn.assigns.scim_provider

    case SSO.scim_deactivate_user(provider, external_id) do
      {:ok, result} -> render_user(conn, :ok, result)
      {:error, reason} -> render_error(conn, reason)
    end
  end

  defp apply_active(conn, external_id, true) do
    provider = conn.assigns.scim_provider

    case SSO.scim_reactivate_user(provider, external_id) do
      {:ok, result} -> render_user(conn, :ok, result)
      {:error, reason} -> render_error(conn, reason)
    end
  end

  # -- PATCH parsing (RFC 7644 §3.5.2) --------------------------------

  # Find the operation that sets `active`. `op` is case-insensitive
  # ("replace"/"Replace"/"add"); `path` is either "active" or omitted with the
  # value carrying `{"active": ...}` (Entra omits path, Okta sends it).
  # Returns {:ok, bool} | :no_active_op (no active op present) | :error
  # (an active op whose value can't be parsed).
  defp active_from_operations(operations) do
    Enum.reduce_while(operations, :no_active_op, fn op, acc ->
      case operation_active(op) do
        :skip -> {:cont, acc}
        :error -> {:halt, :error}
        {:ok, active} -> {:halt, {:ok, active}}
      end
    end)
  end

  defp operation_active(%{} = op) do
    if replace_or_add?(Map.get(op, "op")) do
      active_from_op(Map.get(op, "path"), Map.get(op, "value"))
    else
      :skip
    end
  end

  defp operation_active(_op), do: :skip

  defp replace_or_add?(op) when is_binary(op), do: String.downcase(op) in ["replace", "add"]
  defp replace_or_add?(_), do: false

  # path "active" → the value is the boolean; pathless → the value is a map
  # that may carry "active". Anything else is not an active op.
  defp active_from_op(path, value) when is_binary(path) do
    if String.downcase(path) == "active",
      do: parse_active_value(value),
      else: :skip
  end

  defp active_from_op(nil, %{"active" => value}), do: parse_active_value(value)
  defp active_from_op(_path, _value), do: :skip

  defp parse_active_value(value) do
    case Resource.parse_active(value, nil) do
      nil -> :error
      active -> {:ok, active}
    end
  end

  # Find the operation that replaces `displayName` — same op/path/pathless
  # handling as `active_from_operations/1`. A non-string or empty value is
  # not a rename (the IdP sent nothing usable), never an error.
  defp name_from_operations(operations) do
    Enum.reduce_while(operations, :no_name_op, fn op, acc ->
      case operation_name(op) do
        :skip -> {:cont, acc}
        {:ok, full_name} -> {:halt, {:ok, full_name}}
      end
    end)
  end

  defp operation_name(%{} = op) do
    if replace_or_add?(Map.get(op, "op")) do
      name_from_op(Map.get(op, "path"), Map.get(op, "value"))
    else
      :skip
    end
  end

  defp operation_name(_op), do: :skip

  defp name_from_op(path, value) when is_binary(path) do
    if String.downcase(path) == "displayname" and is_binary(value) and value != "",
      do: {:ok, value},
      else: :skip
  end

  defp name_from_op(nil, %{"displayName" => value}) when is_binary(value) and value != "",
    do: {:ok, value}

  defp name_from_op(_path, _value), do: :skip

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

  defp render_user(conn, status, identity_or_result) do
    conn
    |> put_status(status)
    |> json(Resource.to_user(identity_or_result))
  end

  defp render_error(conn, :not_found), do: not_found(conn, nil)

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

  defp render_error(conn, :email_taken) do
    conn
    |> put_status(:conflict)
    |> json(
      Resource.error(409, "uniqueness", "A user with this email already exists in the account.")
    )
  end

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
