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

  # GET /scim/v2/ServiceProviderConfig
  def service_provider_config(conn, _params) do
    json(conn, %{
      "schemas" => ["urn:ietf:params:scim:schemas:core:2.0:ServiceProviderConfig"],
      "documentationUri" => "#{base_url(conn)}/docs/teams-and-access",
      "patch" => %{"supported" => true},
      "bulk" => %{"supported" => false, "maxOperations" => 0, "maxPayloadSize" => 0},
      "filter" => %{"supported" => true, "maxResults" => 100},
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
    json(conn, Resource.list_response([@user_resource_type]))
  end

  # GET /scim/v2/Schemas
  def schemas(conn, _params) do
    json(conn, Resource.list_response([@user_schema]))
  end

  defp base_url(_conn), do: Emisar.PublicUrl.base()
end
