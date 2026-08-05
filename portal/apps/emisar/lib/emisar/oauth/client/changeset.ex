defmodule Emisar.OAuth.Client.Changeset do
  use Emisar, :changeset
  alias Emisar.OAuth.Client

  @cast_fields ~w(client_name redirect_uris grant_types response_types scope metadata)a

  # The public-client shapes this AS actually supports (mirrors the RFC 8414
  # discovery metadata). A registration requesting anything outside these — the
  # implicit/password/client_credentials grants, a `token` response type — is
  # rejected rather than silently stored and later refused at authorize/token.
  @supported_grant_types ~w(authorization_code refresh_token)
  @supported_response_types ~w(code)
  @cursor_redirect_uri "cursor://anysphere.cursor-mcp/oauth/callback"

  @doc """
  Register a public OAuth client (RFC 7591 Dynamic Client Registration).
  The caller normalizes string/array params first; this validates the
  grant/response/redirect/auth-method shapes against what the AS supports
  and persists the registration.
  """
  def register(attrs) do
    %Client{}
    |> cast(attrs, @cast_fields)
    |> validate_length(:client_name, max: 200)
    |> validate_public_auth_method(attrs)
    |> validate_subset(:grant_types, @supported_grant_types, message: "unsupported grant_type")
    |> validate_subset(:response_types, @supported_response_types,
      message: "unsupported response_type"
    )
    |> validate_application_type()
    |> validate_redirect_uris()
  end

  @doc """
  Build the client row a validated Client ID Metadata Document describes. The
  document is the source of truth on every authorization, so this runs the same
  grant/response/redirect validations as a self-registration — a published
  document cannot claim a shape the authorization server does not support.
  """
  def from_metadata_document(%{} = document, url) do
    %Client{}
    |> cast(
      %{
        client_id_metadata_url: url,
        client_name: document["client_name"],
        redirect_uris: document["redirect_uris"],
        grant_types: document["grant_types"] || ["authorization_code", "refresh_token"],
        response_types: document["response_types"] || ["code"],
        scope: document["scope"] || "mcp offline_access",
        metadata: metadata_from_document(document)
      },
      [:client_id_metadata_url | @cast_fields]
    )
    |> validate_required([:client_id_metadata_url])
    |> validate_length(:client_name, max: 200)
    |> validate_public_auth_method(document)
    |> validate_subset(:grant_types, @supported_grant_types, message: "unsupported grant_type")
    |> validate_subset(:response_types, @supported_response_types,
      message: "unsupported response_type"
    )
    |> validate_application_type()
    |> validate_redirect_uris()
    |> unique_constraint(:client_id_metadata_url)
  end

  @doc "Stamp the client as authorized (an operator completed consent)."
  def mark_authorized(%Client{} = client, %DateTime{} = at),
    do: change(client, last_authorized_at: at)

  defp metadata_from_document(%{"application_type" => application_type})
       when is_binary(application_type),
       do: %{"application_type" => application_type}

  defp metadata_from_document(_document), do: %{}

  # OIDC `application_type` (MCP SEP-837): a client that declares one gets its
  # redirect-URI shape enforced — "web" is https-only, "native" may also use a
  # loopback http redirect (RFC 8252). An absent declaration keeps the
  # permissive pre-SEP-837 set so existing clients register unchanged.
  defp validate_application_type(changeset) do
    case registered_application_type(changeset) do
      nil ->
        changeset

      application_type when application_type in ["web", "native"] ->
        changeset

      _ ->
        add_error(changeset, :application_type, ~s(must be "web" or "native"))
    end
  end

  defp validate_redirect_uris(changeset) do
    uris = get_field(changeset, :redirect_uris) || []
    application_type = registered_application_type(changeset)

    cond do
      uris == [] ->
        add_error(changeset, :redirect_uris, "at least one redirect_uri is required")

      Enum.all?(uris, &valid_redirect_uri?(&1, application_type)) ->
        changeset

      application_type == "web" ->
        add_error(changeset, :redirect_uris, ~s(must be https:// for application_type "web"))

      true ->
        add_error(
          changeset,
          :redirect_uris,
          "must be https://, a native app URI, or http://localhost"
        )
    end
  end

  defp validate_public_auth_method(changeset, attrs) do
    case Map.get(attrs, :token_endpoint_auth_method) ||
           Map.get(attrs, "token_endpoint_auth_method") do
      nil -> changeset
      "none" -> changeset
      _ -> add_error(changeset, :token_endpoint_auth_method, "must be none")
    end
  end

  defp registered_application_type(changeset),
    do: (get_field(changeset, :metadata) || %{})["application_type"]

  # A declared web client receives codes only at an https origin; loopback
  # redirects are a native-app shape it has no business registering.
  defp valid_redirect_uri?(uri, "web") when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: "https", host: host, fragment: nil}
      when is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  # Native (and undeclared) clients may also receive a code through an
  # application-owned URI scheme. RFC 8252 expects the scheme itself to use
  # reverse-domain notation; Cursor instead namespaces its registered handler
  # in the authority, so that exact upstream URI is explicit here. PKCE S256
  # remains mandatory and authorize still requires an exact registered URI.
  defp valid_redirect_uri?(@cursor_redirect_uri, _application_type), do: true

  defp valid_redirect_uri?(uri, _application_type) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: "https", host: host, fragment: nil}
      when is_binary(host) and host != "" ->
        true

      %URI{scheme: "http", host: host, fragment: nil}
      when host in ["localhost", "127.0.0.1", "::1"] ->
        true

      %URI{
        scheme: scheme,
        authority: nil,
        host: nil,
        port: nil,
        path: "/" <> _path,
        fragment: nil,
        userinfo: nil
      }
      when is_binary(scheme) and scheme not in ["http", "https"] ->
        String.contains?(scheme, ".")

      _ ->
        false
    end
  end

  defp valid_redirect_uri?(_, _application_type), do: false
end
