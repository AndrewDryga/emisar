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
      {:ok, manifest} =
        Emisar.Catalog.TrustedManifest.from_catalog_actions([
          %{
            "id" => "a.b",
            "title" => "A",
            "summary" => "A",
            "description" => "A",
            "kind" => "exec",
            "risk" => "low",
            "side_effects" => [],
            "args" => [],
            "examples" => [],
            "search_terms" => []
          }
        ])

      changeset =
        %PackVersion{pending_hash: "sha256:NEW", trust_state: :pending}
        |> Changeset.trust(manifest)
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

  describe "reject_untrusted/1" do
    test "marks the row rejected and KEEPS the refused pending hash" do
      pack_version = %PackVersion{trust_state: :pending, pending_hash: "sha256:NOPE"}
      changeset = Changeset.reject_untrusted(pack_version)

      assert changeset.valid?
      # Only the state flips — the refused bytes stay recorded so judge_drift
      # parks a same-hash re-advertisement instead of re-opening the review.
      assert changeset.changes == %{trust_state: :rejected}
    end
  end

  describe "revoke_trust/1" do
    test "moves a trusted row to rejected, clearing any retirement override" do
      pack_version = %PackVersion{
        trust_state: :trusted,
        hash: "sha256:GOOD",
        retirement_overridden_at: DateTime.utc_now(),
        retirement_overridden_by_id: Ecto.UUID.generate()
      }

      changeset = Changeset.revoke_trust(pack_version)

      assert changeset.valid?

      assert changeset.changes == %{
               trust_state: :rejected,
               retirement_overridden_at: nil,
               retirement_overridden_by_id: nil
             }
    end
  end

  describe "restore_trust/1" do
    test "flips a revoked row back to trusted on its recorded hash" do
      pack_version = %PackVersion{trust_state: :rejected, hash: "sha256:GOOD"}
      changeset = Changeset.restore_trust(pack_version)

      assert changeset.valid?
      assert changeset.changes == %{trust_state: :trusted}
    end

    test "refuses a row with no recorded hash" do
      changeset = Changeset.restore_trust(%PackVersion{trust_state: :rejected, hash: nil})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).hash
    end
  end
end
