defmodule Emisar.Runners.Runner.ChangesetTest do
  use ExUnit.Case, async: true
  import Emisar.DataCase, only: [errors_on: 1]
  alias Emisar.Runners.Runner

  describe "apply_state/2 size caps" do
    setup do
      %{runner: %Runner{id: Ecto.UUID.generate(), account_id: Ecto.UUID.generate()}}
    end

    test "accepts a normal advertisement", %{runner: runner} do
      changeset =
        Runner.Changeset.apply_state(runner, %{
          hostname: "web-01.example.com",
          runner_version: "1.4.2",
          labels: %{"region" => "us-east", "tier" => "edge"},
          packs: %{"linux-core" => %{"version" => "1.2.3"}}
        })

      assert changeset.valid?
    end

    test "rejects an oversized labels map", %{runner: runner} do
      huge = for i <- 1..5_000, into: %{}, do: {"k#{i}", String.duplicate("v", 32)}

      changeset = Runner.Changeset.apply_state(runner, %{labels: huge})

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :labels)
    end

    test "rejects an oversized packs map", %{runner: runner} do
      huge = for i <- 1..5_000, into: %{}, do: {"pack#{i}", String.duplicate("v", 32)}

      changeset = Runner.Changeset.apply_state(runner, %{packs: huge})

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :packs)
    end

    test "rejects an oversized hostname", %{runner: runner} do
      changeset =
        Runner.Changeset.apply_state(runner, %{hostname: String.duplicate("h", 300)})

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :hostname)
    end

    test "rejects an oversized group rename", %{runner: runner} do
      changeset = Runner.Changeset.apply_state(runner, %{group: String.duplicate("g", 81)})

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :group)
    end

    test "rejects an oversized runner_version", %{runner: runner} do
      changeset =
        Runner.Changeset.apply_state(runner, %{runner_version: String.duplicate("9", 300)})

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :runner_version)
    end

    test "rejects a non-positive attestation window", %{runner: runner} do
      changeset = Runner.Changeset.apply_state(runner, %{max_attestation_age_seconds: 0})

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :max_attestation_age_seconds)
    end

    test "requires the freshness window exactly when signature enforcement is enabled", %{
      runner: runner
    } do
      missing = Runner.Changeset.apply_state(runner, %{enforce_signatures: true})
      refute missing.valid?
      assert Keyword.has_key?(missing.errors, :max_attestation_age_seconds)

      paired =
        Runner.Changeset.apply_state(runner, %{
          enforce_signatures: true,
          max_attestation_age_seconds: 3_600
        })

      assert paired.valid?

      stray =
        Runner.Changeset.apply_state(runner, %{
          enforce_signatures: false,
          max_attestation_age_seconds: 3_600
        })

      refute stray.valid?
      assert Keyword.has_key?(stray.errors, :max_attestation_age_seconds)
    end
  end

  describe "register/1 size caps" do
    test "requires a caller-supplied external ID" do
      changeset =
        Runner.Changeset.register(%{
          account_id: Ecto.UUID.generate(),
          name: "web-01",
          group: "edge"
        })

      assert "can't be blank" in errors_on(changeset).external_id
    end

    test "rejects an oversized external ID" do
      changeset =
        Runner.Changeset.register(%{
          account_id: Ecto.UUID.generate(),
          name: "web-01",
          external_id: String.duplicate("x", 256),
          group: "edge"
        })

      assert "should be at most 255 character(s)" in errors_on(changeset).external_id
    end

    test "rejects an oversized hostname at registration" do
      changeset =
        Runner.Changeset.register(%{
          account_id: Ecto.UUID.generate(),
          name: "web-01",
          external_id: Ecto.UUID.generate(),
          group: "edge",
          hostname: String.duplicate("h", 300)
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :hostname)
    end
  end
end
