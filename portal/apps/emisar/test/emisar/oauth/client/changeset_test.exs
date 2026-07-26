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
  end
end
