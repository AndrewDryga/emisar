defmodule Emisar.OAuth.Client.ChangesetTest do
  use Emisar.DataCase, async: true
  alias Emisar.OAuth.Client

  describe "register/1" do
    test "rejects an HTTPS redirect URI without a host" do
      changeset = Client.Changeset.register(%{"redirect_uris" => ["https:///cb"]})

      refute changeset.valid?
      assert "must be https:// or http://localhost" in errors_on(changeset).redirect_uris
    end

    test "rejects a redirect URI with a fragment" do
      changeset =
        Client.Changeset.register(%{
          "redirect_uris" => ["https://client.example/cb#fragment"]
        })

      refute changeset.valid?
      assert "must be https:// or http://localhost" in errors_on(changeset).redirect_uris
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
end
