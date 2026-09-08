defmodule Emisar.SSO.IdentityProvider.ChangesetTest do
  use Emisar.DataCase, async: true
  alias Emisar.Fixtures
  alias Emisar.SSO.IdentityProvider

  describe "JumpCloud issuer validation" do
    test "accepts the exact issuer for each supported region" do
      for issuer <- [
            "https://oauth.id.jumpcloud.com/",
            "https://oauth.id.eu.jumpcloud.com/",
            "https://oauth.id.in.jumpcloud.com/"
          ] do
        attrs = Fixtures.SSO.identity_provider_attrs(kind: :jumpcloud, issuer: issuer)
        changeset = IdentityProvider.Changeset.create(Ecto.UUID.generate(), attrs)

        assert changeset.valid?
        assert changeset.changes.issuer == issuer
      end
    end

    test "rejects unsupported regions and issuer URL variations" do
      for issuer <- [
            "https://accounts.google.com",
            "https://attacker.example.com/",
            "https://oauth.id.au.jumpcloud.com/",
            "https://oauth.id.eu.jumpcloud.com.attacker.example/",
            "https://oauth.id.eu.jumpcloud.com",
            "https://oauth.id.eu.jumpcloud.com:443/",
            "https://oauth.id.eu.jumpcloud.com/tenant",
            "https://oauth.id.eu.jumpcloud.com/?region=eu",
            "https://oauth.id.eu.jumpcloud.com/#issuer",
            "https://user:secret@oauth.id.eu.jumpcloud.com/",
            "http://oauth.id.eu.jumpcloud.com/"
          ] do
        attrs = Fixtures.SSO.identity_provider_attrs(kind: :jumpcloud, issuer: issuer)
        changeset = IdentityProvider.Changeset.create(Ecto.UUID.generate(), attrs)

        assert "must match a supported JumpCloud region" in errors_on(changeset).issuer
      end
    end

    test "requires an explicit region for a new connection" do
      attrs = Fixtures.SSO.identity_provider_attrs(kind: :jumpcloud, issuer: "")
      changeset = IdentityProvider.Changeset.create(Ecto.UUID.generate(), attrs)

      assert "can't be blank" in errors_on(changeset).issuer
    end

    test "an update validates against the persisted kind" do
      provider = %IdentityProvider{kind: :jumpcloud, issuer: "https://oauth.id.jumpcloud.com/"}
      attrs = %{kind: :okta, issuer: "https://attacker.example.com/"}
      changeset = IdentityProvider.Changeset.update(provider, attrs)

      assert "must match a supported JumpCloud region" in errors_on(changeset).issuer
      refute Map.has_key?(changeset.changes, :kind)
    end
  end
end
