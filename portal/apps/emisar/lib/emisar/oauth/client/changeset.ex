defmodule Emisar.OAuth.Client.Changeset do
  use Emisar, :changeset
  alias Emisar.OAuth.Client

  @cast_fields ~w(client_name redirect_uris grant_types response_types
                  token_endpoint_auth_method client_secret_hash scope metadata)a

  @doc """
  Register a public OAuth client (RFC 7591 Dynamic Client Registration).
  The caller normalizes string/array params first; this validates the
  redirect URIs (https or localhost only) and persists the registration.
  """
  def register(attrs) do
    %Client{}
    |> cast(attrs, @cast_fields)
    |> validate_length(:client_name, max: 200)
    |> validate_redirect_uris()
  end

  @doc "Stamp the client as authorized (an operator completed consent)."
  def mark_authorized(%Client{} = client, %DateTime{} = at),
    do: change(client, last_authorized_at: at)

  defp validate_redirect_uris(changeset) do
    uris = get_field(changeset, :redirect_uris) || []

    cond do
      uris == [] ->
        add_error(changeset, :redirect_uris, "at least one redirect_uri is required")

      Enum.all?(uris, &valid_redirect_uri?/1) ->
        changeset

      true ->
        add_error(changeset, :redirect_uris, "must be https:// or http://localhost")
    end
  end

  # Public clients in browsers can only safely receive a code at an
  # https origin (or localhost for native/dev loopback redirects).
  defp valid_redirect_uri?(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: "https"} -> true
      %URI{scheme: "http", host: host} when host in ["localhost", "127.0.0.1", "::1"] -> true
      _ -> false
    end
  end

  defp valid_redirect_uri?(_), do: false
end
