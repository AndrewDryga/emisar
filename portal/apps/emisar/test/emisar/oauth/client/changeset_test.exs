defmodule Emisar.OAuth.Client.ChangesetTest do
  use Emisar.DataCase, async: true
  alias Emisar.OAuth.Client

  @url "https://app.example.com/oauth/client-metadata.json"

  describe "register/1" do
    test "rejects an HTTPS redirect URI without a host" do
      changeset = Client.Changeset.register(%{"redirect_uris" => ["https:///cb"]})

      refute changeset.valid?
      assert redirect_uri_error() in errors_on(changeset).redirect_uris
    end

    test "rejects a redirect URI with a fragment" do
      changeset =
        Client.Changeset.register(%{
          "redirect_uris" => ["https://client.example/cb#fragment"]
        })

      refute changeset.valid?
      assert redirect_uri_error() in errors_on(changeset).redirect_uris
    end

    test "an undeclared application_type keeps the permissive redirect set" do
      changeset =
        Client.Changeset.register(%{"redirect_uris" => ["http://localhost:8123/callback"]})

      assert changeset.valid?
    end

    test ~s(application_type "web" is https-only) do
      changeset =
        Client.Changeset.register(%{
          "redirect_uris" => ["http://localhost:8123/callback"],
          "metadata" => %{"application_type" => "web"}
        })

      refute changeset.valid?

      assert ~s(must be https:// for application_type "web") in errors_on(changeset).redirect_uris
    end

    test ~s(application_type "native" may use a loopback http redirect) do
      changeset =
        Client.Changeset.register(%{
          "redirect_uris" => ["http://127.0.0.1:8123/callback"],
          "metadata" => %{"application_type" => "native"}
        })

      assert changeset.valid?
    end

    test "an undeclared native client may use Cursor's application callback" do
      changeset =
        Client.Changeset.register(%{
          "redirect_uris" => ["cursor://anysphere.cursor-mcp/oauth/callback"]
        })

      assert changeset.valid?
    end

    test "Cursor's scheme exception requires its namespaced authority" do
      changeset =
        Client.Changeset.register(%{
          "redirect_uris" => ["cursor://attacker.example/oauth/callback"]
        })

      refute changeset.valid?
      assert redirect_uri_error() in errors_on(changeset).redirect_uris
    end

    test "Cursor's scheme exception requires its exact callback path and no port" do
      for uri <- [
            "cursor://anysphere.cursor-mcp/other",
            "cursor://anysphere.cursor-mcp:443/oauth/callback"
          ] do
        changeset = Client.Changeset.register(%{"redirect_uris" => [uri]})

        refute changeset.valid?
        assert redirect_uri_error() in errors_on(changeset).redirect_uris
      end
    end

    test "a reverse-domain private-use scheme is accepted for a native client" do
      changeset =
        Client.Changeset.register(%{
          "redirect_uris" => ["com.example.app:/oauth/callback"],
          "metadata" => %{"application_type" => "native"}
        })

      assert changeset.valid?
    end

    test "a reverse-domain private-use scheme cannot carry an authority" do
      changeset =
        Client.Changeset.register(%{
          "redirect_uris" => ["com.example.app://attacker.example/oauth/callback"],
          "metadata" => %{"application_type" => "native"}
        })

      refute changeset.valid?
      assert redirect_uri_error() in errors_on(changeset).redirect_uris
    end

    test ~s(application_type "web" rejects a private-use app callback) do
      changeset =
        Client.Changeset.register(%{
          "redirect_uris" => ["cursor://anysphere.cursor-mcp/oauth/callback"],
          "metadata" => %{"application_type" => "web"}
        })

      refute changeset.valid?

      assert ~s(must be https:// for application_type "web") in errors_on(changeset).redirect_uris
    end

    test "a non-namespaced private-use scheme is rejected" do
      changeset = Client.Changeset.register(%{"redirect_uris" => ["myapp:/oauth/callback"]})

      refute changeset.valid?
      assert redirect_uri_error() in errors_on(changeset).redirect_uris
    end

    test "an unknown application_type is invalid client metadata" do
      changeset =
        Client.Changeset.register(%{
          "redirect_uris" => ["https://client.example/cb"],
          "metadata" => %{"application_type" => "spa"}
        })

      refute changeset.valid?
      assert ~s(must be "web" or "native") in errors_on(changeset).application_type
    end
  end

  describe "from_metadata_document/2" do
    test "builds the client row a published document describes" do
      changeset = Client.Changeset.from_metadata_document(document(), @url)

      assert changeset.valid?
      assert changeset.changes.client_id_metadata_url == @url
      assert changeset.changes.redirect_uris == ["https://app.example.com/callback"]
    end

    test "rejects a client_name that is not a string" do
      changeset = Client.Changeset.from_metadata_document(document(%{"client_name" => 42}), @url)

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).client_name
    end

    test "rejects a client_name carrying a NUL byte" do
      document = document(%{"client_name" => "Example" <> <<0>> <> "Client"})
      changeset = Client.Changeset.from_metadata_document(document, @url)

      refute changeset.valid?

      assert "must not contain control or formatting characters" in errors_on(changeset).client_name
    end

    test "rejects a document that publishes no redirect_uri" do
      changeset =
        Client.Changeset.from_metadata_document(document(%{"redirect_uris" => []}), @url)

      refute changeset.valid?
      assert "at least one redirect_uri is required" in errors_on(changeset).redirect_uris
    end

    test "rejects redirect_uris that are not a list of strings" do
      for uris <- ["https://app.example.com/callback", [1]] do
        changeset =
          Client.Changeset.from_metadata_document(document(%{"redirect_uris" => uris}), @url)

        refute changeset.valid?
        assert "is invalid" in errors_on(changeset).redirect_uris
      end
    end
  end

  defp document(overrides \\ %{}) do
    Map.merge(
      %{
        "client_id" => @url,
        "client_name" => "Example MCP Client",
        "redirect_uris" => ["https://app.example.com/callback"]
      },
      overrides
    )
  end

  defp redirect_uri_error, do: "must be https://, a native app URI, or http://localhost"
end
