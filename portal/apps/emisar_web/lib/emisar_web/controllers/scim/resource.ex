defmodule EmisarWeb.SCIM.Resource do
  @moduledoc """
  The SCIM 2.0 ↔ internal translation — the one module that owns the wire
  shape (RFC 7643/7644). Pure: serializes a `%SSO.UserIdentity{}` (or the domain
  result map) into a SCIM User resource, parses an inbound SCIM payload into
  the flat attrs `Emisar.SSO.scim_provision_user/2` expects, and builds the
  SCIM ListResponse + Error envelopes.

  Parsing is deliberately defensive — IdPs vary in which of `externalId` /
  `userName` / `emails` / `name.formatted` they send — and never calls
  `String.to_atom/1` on input (IL-14): the keys are fixed string literals.
  """
  alias Emisar.SSO

  @user_schema "urn:ietf:params:scim:schemas:core:2.0:User"
  @group_schema "urn:ietf:params:scim:schemas:core:2.0:Group"
  @list_schema "urn:ietf:params:scim:api:messages:2.0:ListResponse"
  @error_schema "urn:ietf:params:scim:api:messages:2.0:Error"

  @doc "The SCIM core User schema URN."
  def user_schema, do: @user_schema

  @doc "The SCIM core Group schema URN."
  def group_schema, do: @group_schema

  @doc """
  Serialize a directory identity to a SCIM User resource. Accepts the
  `%SSO.UserIdentity{}` directly or the `%{identity: ..., user: ...}` result map
  the provision/lifecycle functions return (the user carries the email used
  for `userName`).
  """
  def to_user(%{identity: %SSO.UserIdentity{} = identity} = result),
    do: to_user(identity, result[:user])

  def to_user(%SSO.UserIdentity{} = identity), do: to_user(identity, nil)

  # The SCIM resource `id` is the IdP's externalId, not our internal UUID.
  # SCIM `id` is server-assigned and opaque to the client; the domain keys
  # every single-user operation strictly on externalId (decision 4 —
  # `provider_identifier == scim_external_id`), so making it the canonical
  # `id` lets the IdP's `GET/PATCH/DELETE /Users/{id}` round-trip without a
  # separate UUID→externalId lookup. The internal UUID is never exposed.
  defp to_user(%SSO.UserIdentity{} = identity, user) do
    external_id = identity.scim_external_id || identity.provider_identifier

    %{
      "schemas" => [@user_schema],
      "id" => external_id,
      "externalId" => external_id,
      "userName" => user_name(identity, user),
      "active" => identity.scim_active,
      "meta" => %{"resourceType" => "User"}
    }
  end

  # userName prefers the user's email (the human-readable handle IdPs expect),
  # then a `preferred_username`/`nickname` claim if the IdP asserted one, and
  # only then falls back to the opaque externalId/sub (decision: SCIM email is
  # optional and the IdP may suppress it — but a readable handle is nicer).
  defp user_name(%SSO.UserIdentity{} = identity, user) do
    email_from(identity, user) || username_claim(identity) || identity.scim_external_id ||
      identity.provider_identifier
  end

  defp email_from(_identity, %{email: email}) when is_binary(email) and email != "", do: email

  defp email_from(%SSO.UserIdentity{claims: %{"email" => email}}, _user) when is_binary(email),
    do: email

  defp email_from(_identity, _user), do: nil

  # The common OIDC handle claims, in preference order — a friendlier userName
  # than the raw subject when no email was asserted.
  defp username_claim(%SSO.UserIdentity{claims: claims}) when is_map(claims) do
    Enum.find_value(["preferred_username", "nickname"], fn key ->
      case claims do
        %{^key => value} when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  defp username_claim(_identity), do: nil

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
  defp parse_full_name(params) do
    name = Map.get(params, "name")

    formatted_name(name) || assembled_name(name) || string_or_nil(Map.get(params, "displayName"))
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
  the domain's group upsert/patch returns (`%{external_group_id, display,
  member_*}`) plus the externalId member list to render. `displayName` falls
  back to the externalId when the IdP suppressed it. `members` is the array of
  `%{"value" => externalId}` SCIM expects (an empty group → `[]`).

  Like the User resource, the SCIM `id` is the IdP's externalId — the domain
  keys every group operation on `external_group_id` (there is no internal Group
  UUID to expose), so `GET/PUT/PATCH/DELETE /Groups/{id}` round-trips on it.
  """
  def to_group(%{} = summary, member_external_ids \\ []) when is_list(member_external_ids) do
    external_id = summary[:external_group_id] || summary["external_group_id"]
    display = summary[:display] || summary["display"] || external_id

    %{
      "schemas" => [@group_schema],
      "id" => external_id,
      "displayName" => display,
      "members" => Enum.map(member_external_ids, &%{"value" => &1}),
      "meta" => %{"resourceType" => "Group"}
    }
  end

  @doc """
  Parse an inbound SCIM Group payload into the flat attrs the domain expects:
  `%{external_id, display, member_external_ids}`. `members` may be absent (a
  group create with no members yet) — defaults to `[]`; each entry keys on
  `"value"` (the member's externalId). `externalId` falls back to the resource
  `id` (some IdPs send only one on a PUT).
  """
  def parse_group(%{} = params) do
    %{
      external_id: parse_group_external_id(params),
      display: string_or_nil(Map.get(params, "displayName")),
      member_external_ids: parse_members(Map.get(params, "members"))
    }
  end

  defp parse_group_external_id(params) do
    case Map.get(params, "externalId") do
      id when is_binary(id) and id != "" -> id
      _ -> string_or_nil(Map.get(params, "id"))
    end
  end

  @doc """
  Pull the member externalIds from a SCIM `members` array — each entry is a
  `%{"value" => externalId}` complex attribute. Defensive: a missing array, a
  non-list, or entries without a usable `"value"` yield `[]` / are dropped.
  """
  def parse_members(members) when is_list(members) do
    Enum.flat_map(members, fn
      %{"value" => value} when is_binary(value) and value != "" -> [value]
      _ -> []
    end)
  end

  def parse_members(_members), do: []

  @doc """
  Build a SCIM ListResponse from already-serialized resources. `totalResults`
  is the count of returned resources. A filtered probe (`userName eq …`) is
  matched in the query, so it returns the full match; an UNfiltered list is
  capped at the page limit, so a full reconcile over a directory larger than
  the page sees a partial list (push IdPs filter rather than enumerate — see
  `EmisarWeb.SCIM.UserController.index/2`).
  """
  def list_response(resources) when is_list(resources) do
    %{
      "schemas" => [@list_schema],
      "totalResults" => length(resources),
      "itemsPerPage" => length(resources),
      "startIndex" => 1,
      "Resources" => resources
    }
  end

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
