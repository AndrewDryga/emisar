defmodule Emisar.OAuth.ClientMetadataDocumentTest do
  use Emisar.DataCase, async: true
  alias Emisar.OAuth.ClientMetadataDocument

  @url "https://app.example.com/oauth/client-metadata.json"

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

  describe "metadata_url?/1" do
    test "an https URL selects the metadata-document mechanism" do
      assert ClientMetadataDocument.metadata_url?(@url)
    end

    test "a registration id, a cleartext URL, and a non-binary do not" do
      refute ClientMetadataDocument.metadata_url?(Ecto.UUID.generate())
      refute ClientMetadataDocument.metadata_url?("http://app.example.com/client.json")
      refute ClientMetadataDocument.metadata_url?(nil)
    end
  end

  describe "fetch/1" do
    test "rejects a URL that is not https with a path, before any network work" do
      for url <- [
            "http://app.example.com/client.json",
            "https://app.example.com",
            "https://app.example.com/",
            "https://app.example.com/client.json#frag",
            "https://user:pw@app.example.com/client.json",
            "not-a-url"
          ] do
        assert ClientMetadataDocument.fetch(url) == {:error, :invalid_client_id}
      end
    end

    test "a non-binary client_id is refused" do
      assert ClientMetadataDocument.fetch(nil) == {:error, :invalid_client_id}
    end

    test "refuses a host that resolves into private space" do
      # The SSRF boundary is relaxed in the test environment so fixtures can
      # serve documents from loopback; this is the production posture.
      Emisar.Config.put_override(:emisar, ClientMetadataDocument, allow_private_hosts: false)

      assert ClientMetadataDocument.fetch("https://localhost/client.json") ==
               {:error, :blocked_destination}

      assert ClientMetadataDocument.fetch("https://127.0.0.1/client.json") ==
               {:error, :blocked_destination}

      # The cloud instance-metadata address is the classic SSRF target.
      assert ClientMetadataDocument.fetch("https://169.254.169.254/client.json") ==
               {:error, :blocked_destination}

      assert ClientMetadataDocument.fetch("https://10.0.0.5/client.json") ==
               {:error, :blocked_destination}

      assert ClientMetadataDocument.fetch("https://[::1]/client.json") ==
               {:error, :blocked_destination}
    end
  end

  describe "validate/2" do
    test "accepts a document that matches its URL and carries the required fields" do
      assert ClientMetadataDocument.validate(document(), @url) == {:ok, document()}
    end

    test "rejects a document claiming a client_id other than its own URL" do
      impostor = document(%{"client_id" => "https://victim.example.com/client.json"})

      assert ClientMetadataDocument.validate(impostor, @url) == {:error, :client_id_mismatch}
    end

    test "requires client_id, client_name, and redirect_uris to be present" do
      for field <- ~w(client_id client_name redirect_uris) do
        incomplete = Map.delete(document(), field)

        assert ClientMetadataDocument.validate(incomplete, @url) ==
                 {:error, :missing_required_fields}
      end
    end

    test "rejects a malformed client_name or redirect_uris" do
      assert ClientMetadataDocument.validate(document(%{"client_name" => 42}), @url) ==
               {:error, :invalid_document}

      assert ClientMetadataDocument.validate(document(%{"redirect_uris" => []}), @url) ==
               {:error, :invalid_document}

      assert ClientMetadataDocument.validate(document(%{"redirect_uris" => "https://a/cb"}), @url) ==
               {:error, :invalid_document}

      assert ClientMetadataDocument.validate(document(%{"redirect_uris" => [1]}), @url) ==
               {:error, :invalid_document}
    end
  end
end
