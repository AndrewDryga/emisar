defmodule Emisar.Repo.ChangesetTest do
  @moduledoc """
  The shared `Emisar.Repo.Changeset` helpers, exercised on schemaless changesets
  to keep them pure: `castable/1` (normalize an input schema's attrs for
  `cast/3`), `put_default_value/3` (fill a field only if it's unset — the
  literal, lazy 0-arity fn, changeset-aware 1-arity fn, and copy-from-another-
  field forms together), `truncate_codepoints/3` (cut header-fed text to the
  codepoint count `varchar(n)` enforces), `validate_json_size/3` (cap a
  serialized field size) and `validate_json_value/3` (structural limits before
  that byte cap).
  """
  use ExUnit.Case, async: true
  import Ecto.Changeset
  import Emisar.DataCase, only: [errors_on: 1]
  alias Emisar.Repo.Changeset, as: RepoChangeset

  @types %{name: :string, slug: :string, legal_name: :string}
  @json_limits [max_bytes: 100, max_depth: 2, max_nodes: 3]

  defp changeset(data \\ %{}) do
    base = %{name: nil, slug: nil, legal_name: nil}
    change({Map.merge(base, data), @types})
  end

  defp json_change(value) do
    {%{config: nil}, %{config: :map}} |> change() |> put_change(:config, value)
  end

  describe "castable/1" do
    test "normalizes a keyword list and leaves either map shape alone" do
      assert RepoChangeset.castable(hours: 24) == %{hours: 24}
      assert RepoChangeset.castable(%{"hours" => "24"}) == %{"hours" => "24"}
    end
  end

  describe "put_default_value/3" do
    test "a nil default is a no-op" do
      result = RepoChangeset.put_default_value(changeset(), :name, nil)
      assert get_field(result, :name) == nil
    end

    test "a literal default fills an unset field" do
      result = RepoChangeset.put_default_value(changeset(), :name, "untitled")
      assert get_field(result, :name) == "untitled"
    end

    test "an already-set field is left untouched" do
      result = RepoChangeset.put_default_value(changeset(%{name: "Existing"}), :name, "untitled")
      assert get_field(result, :name) == "Existing"
    end

    test "a 0-arity function default is invoked lazily" do
      result = RepoChangeset.put_default_value(changeset(), :slug, fn -> "generated" end)
      assert get_field(result, :slug) == "generated"
    end

    test "a 1-arity function default receives the changeset" do
      result =
        RepoChangeset.put_default_value(changeset(%{name: "Acme"}), :slug, fn changeset ->
          "slug-of-#{get_field(changeset, :name)}"
        end)

      assert get_field(result, :slug) == "slug-of-Acme"
    end

    test "from: copies another field's value when that field is set" do
      result =
        RepoChangeset.put_default_value(changeset(%{name: "Acme Inc"}), :legal_name, from: :name)

      assert get_field(result, :legal_name) == "Acme Inc"
    end

    test "from: a field that doesn't resolve leaves the target untouched" do
      result = RepoChangeset.put_default_value(changeset(), :legal_name, from: :nonexistent)
      assert get_field(result, :legal_name) == nil
    end
  end

  describe "unique_constraint_error?/1" do
    test "recognizes only unique-constraint failures" do
      unique_error = add_error(changeset(), :name, "has already been taken", constraint: :unique)
      validation_error = add_error(changeset(), :name, "can't be blank", validation: :required)

      assert RepoChangeset.unique_constraint_error?(unique_error)
      refute RepoChangeset.unique_constraint_error?(validation_error)
    end
  end

  describe "truncate_codepoints/3" do
    test "slices to the codepoint limit, not the grapheme limit" do
      # one grapheme (an "a" plus five combining acutes) is six codepoints
      changeset = changeset() |> put_change(:name, "a" <> String.duplicate("\u0301", 5))

      result = RepoChangeset.truncate_codepoints(changeset, [:name], 3)

      assert result.changes == %{name: "a\u0301\u0301"}
      assert String.length(result.changes.name) == 1
    end

    test "a change within the limit is untouched and an unset field stays unset" do
      changeset = changeset() |> put_change(:name, "abc")

      result = RepoChangeset.truncate_codepoints(changeset, [:name, :slug], 10)

      assert result.changes == %{name: "abc"}
    end

    test "a non-binary change passes through unchanged" do
      changeset = changeset() |> put_change(:name, 42)

      result = RepoChangeset.truncate_codepoints(changeset, [:name], 1)

      assert result.changes == %{name: 42}
    end
  end

  describe "validate_json_size/3" do
    test "an unset field passes through" do
      result =
        RepoChangeset.validate_json_size(change({%{config: nil}, %{config: :map}}), :config, 100)

      assert result.valid?
    end

    test "a value within the byte budget passes" do
      assert RepoChangeset.validate_json_size(json_change(%{"a" => "x"}), :config, 100).valid?
    end

    test "a value Jason cannot encode passes through unchanged" do
      assert RepoChangeset.validate_json_size(json_change(self()), :config, 100).valid?
    end

    test "a value whose serialized JSON exceeds max_bytes errors on the field" do
      result =
        RepoChangeset.validate_json_size(
          json_change(%{"a" => String.duplicate("x", 200)}),
          :config,
          100
        )

      refute result.valid?
      assert "is too large (max 100 bytes serialized)" in errors_on(result).config
    end
  end

  describe "validate_json_value/3" do
    test "an unset field passes through" do
      changeset = change({%{config: nil}, %{config: :map}})

      assert RepoChangeset.validate_json_value(changeset, :config, @json_limits).valid?
    end

    test "a value within every limit passes" do
      changeset = json_change(%{"a" => "x"})

      assert RepoChangeset.validate_json_value(changeset, :config, @json_limits).valid?
    end

    test "a value nested past max_depth errors on the field" do
      changeset = json_change(%{"a" => %{"b" => "x"}})

      result = RepoChangeset.validate_json_value(changeset, :config, @json_limits)

      refute result.valid?
      assert errors_on(result) == %{config: ["is nested too deeply"]}
    end

    test "a value with more than max_nodes values errors on the field" do
      changeset = json_change(["a", "b", "c", "d"])

      result = RepoChangeset.validate_json_value(changeset, :config, @json_limits)

      refute result.valid?
      assert errors_on(result) == %{config: ["has too many values"]}
    end

    test "a value that is not JSON errors on the field" do
      changeset = json_change(%{"pid" => self()})

      result = RepoChangeset.validate_json_value(changeset, :config, @json_limits)

      refute result.valid?
      assert errors_on(result) == %{config: ["must contain JSON values"]}
    end

    test "a structurally valid value still gets the max_bytes check" do
      changeset = json_change(%{"a" => String.duplicate("x", 200)})

      result = RepoChangeset.validate_json_value(changeset, :config, @json_limits)

      refute result.valid?
      assert errors_on(result) == %{config: ["is too large (max 100 bytes serialized)"]}
    end
  end
end
