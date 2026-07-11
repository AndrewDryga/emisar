defmodule Emisar.Catalog.PackVersion.ChangesetTest do
  use Emisar.DataCase, async: true
  alias Emisar.Catalog.PackVersion
  alias Emisar.Catalog.PackVersion.Changeset

  describe "override_retirement/2" do
    test "stamps the override timestamp + who on a pack-version struct" do
      changeset = Changeset.override_retirement(%PackVersion{}, "user-123")

      assert changeset.valid?
      assert %DateTime{} = changeset.changes.retirement_overridden_at
      assert changeset.changes.retirement_overridden_by_id == "user-123"
    end

    # The trust-of-a-retired-version path (unreachable via the compiled baseline
    # in tests) composes override_retirement onto trust/2 — this proves the
    # changeset-input arm keeps the trust changes AND adds the override.
    test "composes onto trust/2 — keeps the trust flip and adds the override" do
      changeset =
        %PackVersion{pending_hash: "sha256:NEW", trust_state: :pending}
        |> Changeset.trust(%{"a.b" => %{}})
        |> Changeset.override_retirement("user-9")

      assert changeset.valid?
      assert changeset.changes.hash == "sha256:NEW"
      assert changeset.changes.trust_state == :trusted
      assert changeset.changes.retirement_overridden_by_id == "user-9"
      assert %DateTime{} = changeset.changes.retirement_overridden_at
    end

    test "requires the overriding user id" do
      changeset = Changeset.override_retirement(%PackVersion{}, nil)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).retirement_overridden_by_id
    end
  end
end
