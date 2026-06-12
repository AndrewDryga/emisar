defmodule Emisar.OAuthTest do
  @moduledoc """
  The OAuth 2.1 authorization server: DCR, authorization-code + PKCE,
  refresh-token rotation, and access-token resolution to the backing
  API key. These are the paths the Claude.ai / ChatGPT connectors drive.
  """
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.OAuth
  alias Emisar.OAuth.Client

  @redirect "https://claude.ai/api/mcp/auth_callback"
  @resource "https://emisar.dev/api/mcp/rpc"

  defp pkce do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
    {verifier, challenge}
  end

  defp register!(name \\ "Claude") do
    {:ok, client} =
      OAuth.register_client(%{"client_name" => name, "redirect_uris" => [@redirect]})

    client
  end

  defp issue!(subject, client, challenge, opts \\ []) do
    {:ok, code} =
      OAuth.issue_code(
        client,
        %{
          "redirect_uri" => @redirect,
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "scope" => opts[:scope] || "mcp offline_access",
          "resource" => @resource
        },
        subject
      )

    code
  end

  describe "register_client/1" do
    test "registers a PKCE public client (auth method none)" do
      assert {:ok, %Client{} = client} =
               OAuth.register_client(%{
                 "client_name" => "ChatGPT",
                 "redirect_uris" => [@redirect]
               })

      assert client.token_endpoint_auth_method == "none"
      assert client.client_name == "ChatGPT"
      assert @redirect in client.redirect_uris
    end

    test "rejects a non-https / non-localhost redirect uri" do
      assert {:error, changeset} =
               OAuth.register_client(%{"redirect_uris" => ["http://evil.example/cb"]})

      refute changeset.valid?
    end

    test "requires at least one redirect uri" do
      assert {:error, _changeset} = OAuth.register_client(%{"client_name" => "X"})
    end
  end

  describe "issue_code/3 authorization gate" do
    test "a read-only viewer cannot consent — the OAuth flow can't mint an execute token they couldn't issue manually" do
      {_owner, account, _subject} = owner_subject_fixture()
      client = register!()
      {_verifier, challenge} = pkce()
      # A viewer has view_api_keys but not issue_quick_key, so they can't mint
      # an API key in-product — and must not be able to via consent either.
      viewer = subject_for(user_fixture(), account, role: :viewer)

      assert {:error, :unauthorized} =
               OAuth.issue_code(
                 client,
                 %{
                   "redirect_uri" => @redirect,
                   "code_challenge" => challenge,
                   "code_challenge_method" => "S256",
                   "scope" => "mcp offline_access",
                   "resource" => @resource
                 },
                 viewer
               )
    end
  end

  describe "authorization-code flow" do
    setup do
      {_user, account, subject} = owner_subject_fixture()
      %{account: account, subject: subject, client: register!()}
    end

    test "issue + exchange yields tokens bound to a backing key",
         %{subject: subject, client: client, account: account} do
      {verifier, challenge} = pkce()
      code = issue!(subject, client, challenge)

      assert {:ok, tokens} =
               OAuth.exchange_code(%{
                 "code" => code,
                 "client_id" => client.id,
                 "redirect_uri" => @redirect,
                 "code_verifier" => verifier
               })

      assert "emo-" <> _ = tokens.access_token
      assert "emor-" <> _ = tokens.refresh_token
      assert tokens.token_type == "Bearer"
      assert tokens.expires_in == 3600

      assert {:ok, %{api_key: key, account: acct}} =
               OAuth.resolve_access_token(tokens.access_token)

      assert acct.id == account.id
      assert "actions:read" in key.scopes
      assert "actions:execute" in key.scopes
    end

    test "consent audits oauth.consent_granted with the backing key as subject",
         %{subject: subject, client: client} do
      {_verifier, challenge} = pkce()
      _code = issue!(subject, client, challenge)

      {:ok, [event], _meta} =
        Emisar.Audit.list_events(subject, filter: [event_type: ["oauth.consent_granted"]])

      assert event.actor_id == Emisar.Auth.Subject.actor_id(subject)
      assert event.subject_kind == "api_key"
      assert event.payload["client_id"] == client.id
      assert event.payload["scopes"] == ["actions:read", "actions:execute"]
    end

    test "rejects a tampered PKCE verifier", %{subject: subject, client: client} do
      {_verifier, challenge} = pkce()
      code = issue!(subject, client, challenge)

      assert {:error, :invalid_grant} =
               OAuth.exchange_code(%{
                 "code" => code,
                 "client_id" => client.id,
                 "redirect_uri" => @redirect,
                 "code_verifier" => "definitely-the-wrong-verifier"
               })
    end

    test "the code is single-use", %{subject: subject, client: client} do
      {verifier, challenge} = pkce()
      code = issue!(subject, client, challenge)

      params = %{
        "code" => code,
        "client_id" => client.id,
        "redirect_uri" => @redirect,
        "code_verifier" => verifier
      }

      assert {:ok, _} = OAuth.exchange_code(params)
      assert {:error, :invalid_grant} = OAuth.exchange_code(params)
    end

    test "rejects a mismatched redirect_uri", %{subject: subject, client: client} do
      {verifier, challenge} = pkce()
      code = issue!(subject, client, challenge)

      assert {:error, :invalid_grant} =
               OAuth.exchange_code(%{
                 "code" => code,
                 "client_id" => client.id,
                 "redirect_uri" => "https://claude.ai/somewhere-else",
                 "code_verifier" => verifier
               })
    end

    test "rejects a code replayed by a different client",
         %{subject: subject, client: client} do
      other = register!("Other")
      {verifier, challenge} = pkce()
      code = issue!(subject, client, challenge)

      assert {:error, :invalid_grant} =
               OAuth.exchange_code(%{
                 "code" => code,
                 "client_id" => other.id,
                 "redirect_uri" => @redirect,
                 "code_verifier" => verifier
               })
    end

    test "omits the refresh token when offline_access is not requested",
         %{subject: subject, client: client} do
      {verifier, challenge} = pkce()
      code = issue!(subject, client, challenge, scope: "mcp")

      assert {:ok, tokens} =
               OAuth.exchange_code(%{
                 "code" => code,
                 "client_id" => client.id,
                 "redirect_uri" => @redirect,
                 "code_verifier" => verifier
               })

      assert tokens.refresh_token == nil
    end
  end

  describe "refresh/1" do
    setup do
      {_user, account, subject} = owner_subject_fixture()
      client = register!()
      {verifier, challenge} = pkce()
      code = issue!(subject, client, challenge)

      {:ok, tokens} =
        OAuth.exchange_code(%{
          "code" => code,
          "client_id" => client.id,
          "redirect_uri" => @redirect,
          "code_verifier" => verifier
        })

      %{account: account, client: client, tokens: tokens}
    end

    test "rotates the refresh token and issues a fresh access token",
         %{client: client, tokens: tokens} do
      assert {:ok, fresh} =
               OAuth.refresh(%{
                 "refresh_token" => tokens.refresh_token,
                 "client_id" => client.id
               })

      assert "emo-" <> _ = fresh.access_token
      assert fresh.access_token != tokens.access_token
      assert "emor-" <> _ = fresh.refresh_token
      assert fresh.refresh_token != tokens.refresh_token

      # The rotated (old) refresh token is dead.
      assert {:error, :invalid_grant} =
               OAuth.refresh(%{
                 "refresh_token" => tokens.refresh_token,
                 "client_id" => client.id
               })

      # The new access token resolves.
      assert {:ok, _} = OAuth.resolve_access_token(fresh.access_token)
    end

    test "fails closed once the backing api_key is revoked", %{client: client, tokens: tokens} do
      # Revoking the backing key is the operator's off-switch for an OAuth
      # connection — refresh must then stop minting access tokens, not keep
      # the 30-day grant alive over a dead key.
      {:ok, %{api_key: key}} = OAuth.resolve_access_token(tokens.access_token)

      key
      |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
      |> Emisar.Repo.update!()

      assert {:error, :invalid_grant} =
               OAuth.refresh(%{
                 "refresh_token" => tokens.refresh_token,
                 "client_id" => client.id
               })
    end

    test "rejects a refresh token presented by the wrong client",
         %{tokens: tokens} do
      other = register!("Other")

      assert {:error, :invalid_grant} =
               OAuth.refresh(%{
                 "refresh_token" => tokens.refresh_token,
                 "client_id" => other.id
               })
    end
  end

  describe "resolve_access_token/1" do
    test "rejects unknown / malformed tokens" do
      assert {:error, :invalid} = OAuth.resolve_access_token("emo-not-a-real-token")
      assert {:error, :invalid} = OAuth.resolve_access_token("garbage")
      assert {:error, :invalid} = OAuth.resolve_access_token(nil)
    end
  end
end
