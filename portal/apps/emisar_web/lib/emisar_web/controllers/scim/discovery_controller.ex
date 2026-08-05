defmodule EmisarWeb.SCIM.DiscoveryController do
  @moduledoc """
  The SCIM 2.0 discovery endpoints (RFC 7643 §§5–7) IdPs probe before they
  push users: `ServiceProviderConfig`, `ResourceTypes`, and `Schemas`. The
  payloads are mostly-static and declare exactly the subset emisar supports —
  patch yes, filter yes (capped), no bulk / sort / etag / password-change,
  bearer auth only.

  All three sit behind `SCIM.Auth` (IdPs send the bearer when probing), so the
  acting provider is already resolved — the config we return is the same for
  every provider, but the auth gate keeps the surface uniformly token-only.
  """
  use EmisarWeb, :controller
  alias EmisarWeb.SCIM.Resource

  plug EmisarWeb.SCIM.Auth

  @user_resource_type %{
    "schemas" => ["urn:ietf:params:scim:schemas:core:2.0:ResourceType"],
    "id" => "User",
    "name" => "User",
    "endpoint" => "/Users",
    "description" => "SCIM User — directory-synced account members.",
    "schema" => "urn:ietf:params:scim:schemas:core:2.0:User",
    "meta" => %{
      "resourceType" => "ResourceType",
      "location" => "/scim/v2/ResourceTypes/User"
    }
  }

  @user_schema %{
    "id" => "urn:ietf:params:scim:schemas:core:2.0:User",
    "name" => "User",
    "description" => "SCIM core User schema (subset).",
    "meta" => %{"resourceType" => "Schema"},
    "attributes" => [
      %{
        "name" => "userName",
        "type" => "string",
        "multiValued" => false,
        "required" => true,
        "caseExact" => false,
        "mutability" => "readWrite",
        "uniqueness" => "server"
      },
      %{
        "name" => "active",
        "type" => "boolean",
        "multiValued" => false,
        "required" => false,
        "mutability" => "readWrite"
      },
      %{
        "name" => "externalId",
        "type" => "string",
        "multiValued" => false,
        "required" => false,
        "caseExact" => true,
        "mutability" => "readWrite"
      }
    ]
  }

  # Groups have complete routes, but an IdP that decides what to push by reading
  # discovery was told only about Users — so it never pushed a group at all, and
  # every group→role mapping stayed unfed.
  @group_resource_type %{
    "schemas" => ["urn:ietf:params:scim:schemas:core:2.0:ResourceType"],
    "id" => "Group",
    "name" => "Group",
    "endpoint" => "/Groups",
    "description" => "SCIM Group — directory groups emisar maps to roles and runner access.",
    "schema" => "urn:ietf:params:scim:schemas:core:2.0:Group",
    "meta" => %{
      "resourceType" => "ResourceType",
      "location" => "/scim/v2/ResourceTypes/Group"
    }
  }

  @group_schema %{
    "id" => "urn:ietf:params:scim:schemas:core:2.0:Group",
    "name" => "Group",
    "description" => "SCIM core Group schema (subset).",
    "meta" => %{"resourceType" => "Schema"},
    "attributes" => [
      %{
        "name" => "displayName",
        "type" => "string",
        "multiValued" => false,
        "required" => true,
        "caseExact" => false,
        "mutability" => "readWrite",
        "uniqueness" => "none"
      },
      %{
        "name" => "externalId",
        "type" => "string",
        "multiValued" => false,
        "required" => false,
        "caseExact" => true,
        "mutability" => "readWrite"
      },
      %{
        "name" => "members",
        "type" => "complex",
        "multiValued" => true,
        "required" => false,
        "mutability" => "readWrite",
        "subAttributes" => [
          %{
            "name" => "value",
            "type" => "string",
            "multiValued" => false,
            "required" => true,
            "caseExact" => true,
            "mutability" => "immutable"
          }
        ]
      }
    ]
  }

  # GET /scim/v2/ServiceProviderConfig
  def service_provider_config(conn, _params) do
    json(conn, %{
      "schemas" => ["urn:ietf:params:scim:schemas:core:2.0:ServiceProviderConfig"],
      "documentationUri" => "#{base_url(conn)}/docs/scim",
      "patch" => %{"supported" => true},
      "bulk" => %{"supported" => false, "maxOperations" => 0, "maxPayloadSize" => 0},
      "filter" => %{"supported" => true, "maxResults" => Resource.max_page_size()},
      "changePassword" => %{"supported" => false},
      "sort" => %{"supported" => false},
      "etag" => %{"supported" => false},
      "authenticationSchemes" => [
        %{
          "type" => "oauthbearertoken",
          "name" => "OAuth Bearer Token",
          "description" => "Authentication via the per-provider SCIM bearer token.",
          "primary" => true
        }
      ],
      "meta" => %{
        "resourceType" => "ServiceProviderConfig",
        "location" => "#{base_url(conn)}/scim/v2/ServiceProviderConfig"
      }
    })
  end

  # GET /scim/v2/ResourceTypes
  def resource_types(conn, _params) do
    resources = [@user_resource_type, @group_resource_type]
    json(conn, Resource.list_response(resources, length(resources), 1))
  end

  # GET /scim/v2/ResourceTypes/:id — RFC 7643 §6 gives each type its own URL, and
  # the `meta.location` above points at it.
  def resource_type(conn, %{"id" => "User"}), do: json(conn, @user_resource_type)
  def resource_type(conn, %{"id" => "Group"}), do: json(conn, @group_resource_type)

  def resource_type(conn, %{"id" => id}) do
    conn
    |> put_status(:not_found)
    |> json(Resource.error(404, "No SCIM ResourceType `#{id}`."))
  end

  # GET /scim/v2/Schemas
  def schemas(conn, _params) do
    resources = [@user_schema, @group_schema]
    json(conn, Resource.list_response(resources, length(resources), 1))
  end

  # GET /scim/v2/Schemas/:id
  def schema(conn, %{"id" => "urn:ietf:params:scim:schemas:core:2.0:User"}),
    do: json(conn, @user_schema)

  def schema(conn, %{"id" => "urn:ietf:params:scim:schemas:core:2.0:Group"}),
    do: json(conn, @group_schema)

  def schema(conn, %{"id" => id}) do
    conn
    |> put_status(:not_found)
    |> json(Resource.error(404, "No SCIM Schema `#{id}`."))
  end

  defp base_url(_conn), do: Emisar.PublicUrl.base()
end
