defmodule EmisarWeb.SCIM.Resource do
  @moduledoc """
  The SCIM 2.0 ↔ internal translation — the one module that owns the wire
  shape (RFC 7643/7644). Pure: maps the `%SSO.SCIMUser{}` projection onto a
  SCIM User resource's RFC 7643 field names (every directory fact — effective
  active state, externalId choice, userName fallback — is decided in
  `Emisar.SSO`), parses an inbound SCIM payload into the flat attrs
  `Emisar.SSO.scim_provision_user/2` expects, and builds the SCIM ListResponse
  + Error envelopes.

  Parsing is deliberately defensive — IdPs vary in which of `externalId` /
  `userName` / `emails` / `name.formatted` they send — and never calls
  `String.to_atom/1` on input (IL-14): the keys are fixed string literals.
  """
  alias Emisar.SSO

  @user_schema "urn:ietf:params:scim:schemas:core:2.0:User"
  @group_schema "urn:ietf:params:scim:schemas:core:2.0:Group"
  @list_schema "urn:ietf:params:scim:api:messages:2.0:ListResponse"
  @error_schema "urn:ietf:params:scim:api:messages:2.0:Error"
  @max_page_size 100

  @doc "The SCIM core User schema URN."
  def user_schema, do: @user_schema

  @doc "The SCIM core Group schema URN."
  def group_schema, do: @group_schema

  @doc """
  Serialize the `%SSO.SCIMUser{}` directory-user projection to a SCIM User
  resource. `id` is the server-issued immutable resource UUID; `externalId`
  remains the directory-owned correlation value.
  """
  def to_user(%SSO.SCIMUser{} = scim_user) do
    # `displayName` and `name` are what the IdP wrote and expects to read back.
    # Omitting them made a rename look like it had not applied: the directory
    # pushed a new name, we stored it, and every subsequent read answered with no
    # name at all.
    %{
      "schemas" => [@user_schema],
      "id" => scim_user.id,
      "externalId" => scim_user.external_id,
      "userName" => scim_user.user_name,
      "active" => scim_user.active,
      "meta" => %{"resourceType" => "User"}
    }
    |> put_name(scim_user.display_name)
  end

  defp put_name(resource, name) when is_binary(name) and name != "" do
    resource
    |> Map.put("displayName", name)
    |> Map.put("name", %{"formatted" => name})
  end

  defp put_name(resource, _name), do: resource

  @doc """
  Parse an inbound SCIM User payload into the flat attrs the domain expects:
  `%{external_id, email, full_name, active}`. Pulls each field defensively
  across the shapes real IdPs send; `active` defaults to `true` (a create
  with no `active` is an active user per RFC 7644 §4.1.1).
  """
  def parse_user(%{} = params) do
    %{
      external_id: parse_external_id(params),
      email: parse_email(params),
      full_name: parse_full_name(params),
      active: parse_active(Map.get(params, "active"), true)
    }
  end

  # externalId is the binding identifier (decision 4); fall back to userName
  # when an IdP omits externalId on create (some send only userName).
  defp parse_external_id(params) do
    case Map.get(params, "externalId") do
      id when is_binary(id) and id != "" -> id
      _ -> string_or_nil(Map.get(params, "userName"))
    end
  end

  # `emails` is an array of `%{"value" => ..., "primary" => bool}`; prefer the
  # primary, else the first with a value. Fall back to a bare `userName` that
  # looks like an email (Okta/Entra commonly set userName to the email).
  defp parse_email(params) do
    emails = Map.get(params, "emails")

    primary_email(emails) || first_email(emails) || email_like_user_name(params)
  end

  defp primary_email(emails) when is_list(emails) do
    Enum.find_value(emails, fn
      %{"primary" => true, "value" => value} when is_binary(value) and value != "" -> value
      _ -> nil
    end)
  end

  defp primary_email(_), do: nil

  defp first_email(emails) when is_list(emails) do
    Enum.find_value(emails, fn
      %{"value" => value} when is_binary(value) and value != "" -> value
      _ -> nil
    end)
  end

  defp first_email(_), do: nil

  defp email_like_user_name(params) do
    case Map.get(params, "userName") do
      name when is_binary(name) -> if String.contains?(name, "@"), do: name, else: nil
      _ -> nil
    end
  end

  # Prefer `name.formatted`; else join `givenName` + `familyName`; else
  # `displayName`. Returns nil when the IdP sent nothing usable.
  # `displayName` first. Serving `name.formatted` back to the IdP means the IdP
  # echoes it on the next write — Okta sends a stale `name.formatted` alongside a
  # FRESH `displayName` and fresh name components, and preferring the formatted
  # value meant a rename was accepted, reported successful, and silently kept the
  # old name. The freshest signal a client sends wins; `formatted` stays as the
  # fallback for clients that send nothing else.
  defp parse_full_name(params) do
    name = Map.get(params, "name")

    string_or_nil(Map.get(params, "displayName")) || assembled_name(name) || formatted_name(name)
  end

  defp formatted_name(%{"formatted" => formatted}) when is_binary(formatted) and formatted != "",
    do: formatted

  defp formatted_name(_), do: nil

  defp assembled_name(%{} = name) do
    [Map.get(name, "givenName"), Map.get(name, "familyName")]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " ")
    end
  end

  defp assembled_name(_), do: nil

  @doc """
  Parse a SCIM `active` value tolerantly into a boolean, or `nil` when the
  payload carries no `active` signal. IdPs send a JSON boolean, but some send
  the strings `"True"`/`"False"` (Entra) — both are honored. A `default` is
  returned only when the value is absent (`nil`); an unparseable present value
  yields `nil` so the caller can treat it as "no active change".
  """
  def parse_active(nil, default), do: default
  def parse_active(value, _default) when is_boolean(value), do: value

  def parse_active(value, _default) when is_binary(value) do
    case String.downcase(value) do
      "true" -> true
      "false" -> false
      _ -> nil
    end
  end

  def parse_active(_value, _default), do: nil

  @doc """
  Serialize a directory group to a SCIM Group resource. Accepts the summary map
  the domain's group upsert/patch returns (`%{id, external_group_id, display,
  member_ids}`) plus the server-issued User ids to render. `displayName` falls
  back to the externalId when the IdP suppressed it. An externalId-less probe
  must supply a display name. `members` is the array of User resource ids.
  """
  def to_group(%{} = summary, member_ids \\ []) when is_list(member_ids) do
    id = summary[:id] || summary["id"]
    external_id = summary[:external_group_id] || summary["external_group_id"]
    display = summary[:display] || summary["display"] || external_id || id

    # `externalId` matters as much on a group as on a user. Without it Entra reads
    # back the group it just created, sees the field missing, and PATCHes to set
    # it — a PATCH we answer 400 to, which stops that group's sync dead and
    # leaves its role mapping permanently unapplied.
    resource = %{
      "schemas" => [@group_schema],
      "id" => id,
      "displayName" => display,
      "members" => Enum.map(member_ids, &%{"value" => &1}),
      "meta" => %{"resourceType" => "Group"}
    }

    if external_id, do: Map.put(resource, "externalId", external_id), else: resource
  end

  @doc """
  Parse an inbound SCIM Group payload into the flat attrs the domain expects:
  `%{external_id, display, member_ids}`. `members` may be absent (a group create
  with no members yet) — defaults to `[]`; each entry keys on `"value"`, the
  server-issued User resource id. `id` and `displayName` never become identity
  fallbacks for `externalId`.
  """
  def parse_group(%{} = params) do
    %{
      external_id: parse_group_external_id(params),
      display: string_or_nil(Map.get(params, "displayName")),
      member_ids: parse_members(Map.get(params, "members"))
    }
  end

  defp parse_group_external_id(params) do
    case Map.get(params, "externalId") do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  @doc """
  Pull the server-issued User ids from a SCIM `members` array. Defensive: a missing array, a
  non-list, or entries without a usable `"value"` yield `[]` / are dropped.
  """
  def parse_members(members) when is_list(members) do
    Enum.flat_map(members, fn
      %{"value" => value} when is_binary(value) and value != "" -> [value]
      _ -> []
    end)
  end

  def parse_members(_members), do: []

  @doc "Whether a SCIM Group `members` value is absent or a well-formed member array."
  def valid_members?(nil), do: true

  def valid_members?(members) when is_list(members) do
    Enum.all?(members, fn
      %{"value" => value} when is_binary(value) and value != "" -> true
      _ -> false
    end)
  end

  def valid_members?(_members), do: false

  @doc "The maximum number of resources returned by one SCIM collection request."
  def max_page_size, do: @max_page_size

  @doc """
  Parse RFC 7644 `startIndex` and `count` collection parameters.

  SCIM indexes are one-based. Missing values default to the first 100 results,
  a `startIndex` below one is normalized to one, and `count` is clamped to
  `0..100`. A malformed integer is rejected instead of being silently ignored.
  """
  def parse_pagination(params) when is_map(params) do
    with {:ok, start_index} <- parse_integer(Map.get(params, "startIndex"), 1),
         {:ok, count} <- parse_integer(Map.get(params, "count"), @max_page_size) do
      {:ok,
       %{
         start_index: max(start_index, 1),
         count: count |> max(0) |> min(@max_page_size)
       }}
    end
  end

  @doc "Build a SCIM ListResponse from one serialized page and its truthful total."
  def list_response(resources, total_results, start_index)
      when is_list(resources) and is_integer(total_results) and is_integer(start_index) do
    %{
      "schemas" => [@list_schema],
      "totalResults" => total_results,
      "itemsPerPage" => length(resources),
      "startIndex" => start_index,
      "Resources" => resources
    }
  end

  defp parse_integer(nil, default), do: {:ok, default}
  defp parse_integer(value, _default) when is_integer(value), do: {:ok, value}

  defp parse_integer(value, _default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _ -> {:error, :invalid_pagination}
    end
  end

  defp parse_integer(_value, _default), do: {:error, :invalid_pagination}

  @doc "A SCIM Error resource. `status` is the HTTP status as an integer."
  def error(status, detail) when is_integer(status) and is_binary(detail) do
    %{
      "schemas" => [@error_schema],
      "status" => Integer.to_string(status),
      "detail" => detail
    }
  end

  @doc """
  A SCIM Error resource carrying a `scimType` (RFC 7644 §3.12) — used for the
  typed 4xx errors (e.g. `mutability` when a PATCH op targets an unsupported
  path).
  """
  def error(status, scim_type, detail)
      when is_integer(status) and is_binary(scim_type) and is_binary(detail) do
    status
    |> error(detail)
    |> Map.put("scimType", scim_type)
  end

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_), do: nil
end
