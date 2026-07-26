defmodule Emisar.Catalog.PackVersion.ChangesetTest do
  use Emisar.DataCase, async: true
  alias Emisar.Catalog.PackVersion
  alias Emisar.Catalog.PackVersion.Changeset

  @valid_pack_hash "sha256:" <> String.duplicate("a", 64)

  defp insert_attrs(extra) do
    now = DateTime.utc_now()

    Map.merge(
      %{
        account_id: Ecto.UUID.generate(),
        pack_id: "linux-core",
        version: "1.0.0",
        hash: @valid_pack_hash,
        trust_state: :trusted,
        first_seen_at: now,
        last_seen_at: now
      },
      extra
    )
  end

  describe "insert/1" do
    test "accepts the runner pack metadata boundaries" do
      attrs =
        insert_attrs(%{
          pack_id: String.duplicate("a", 128),
          version: String.duplicate("1", 64),
          hash: @valid_pack_hash
        })

      assert Changeset.insert(attrs).valid?
    end

    test "rejects pack metadata just past its length boundaries" do
      attrs =
        insert_attrs(%{
          pack_id: String.duplicate("a", 129),
          version: String.duplicate("1", 65),
          hash: @valid_pack_hash <> "a",
          pending_hash: @valid_pack_hash <> "a"
        })

      errors = attrs |> Changeset.insert() |> errors_on()

      assert "should be at most 128 character(s)" in errors.pack_id
      assert "should be at most 64 character(s)" in errors.version
      assert "should be at most 71 character(s)" in errors.hash
      assert "should be at most 71 character(s)" in errors.pending_hash
    end

    test "rejects malformed pack ids, versions, and hashes" do
      attrs =
        insert_attrs(%{
          pack_id: "INVALID/PACK",
          version: "1.0/../escape",
          hash: "sha256:" <> String.duplicate("A", 64),
          pending_hash: "not-a-sha256"
        })

      errors = attrs |> Changeset.insert() |> errors_on()

      assert "has invalid format" in errors.pack_id
      assert "has invalid format" in errors.version
      assert "has invalid format" in errors.hash
      assert "has invalid format" in errors.pending_hash
    end
  end

  describe "mark_pending/3" do
    test "rejects a malformed runner-advertised hash" do
      changeset =
        Changeset.mark_pending(%PackVersion{}, "not-a-sha256", DateTime.utc_now())

      refute changeset.valid?
      assert "has invalid format" in errors_on(changeset).pending_hash
    end
  end

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
        %PackVersion{pending_hash: @valid_pack_hash, trust_state: :pending}
        |> Changeset.trust(manifest)
        |> Changeset.override_retirement("user-9")

      assert changeset.valid?
      assert changeset.changes.hash == @valid_pack_hash
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
