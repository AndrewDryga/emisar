defmodule Emisar.Repo.ChangesetTest do
  @moduledoc """
  The shared `Emisar.Repo.Changeset` helpers, exercised on schemaless changesets
  to keep them pure: `put_default_value/3` (fill a field only if it's unset — the
  literal, lazy 0-arity fn, changeset-aware 1-arity fn, and copy-from-another-
  field forms together) and `validate_json_size/3` (cap a serialized field size).
  """
  use ExUnit.Case, async: true

  import Ecto.Changeset

  alias Emisar.Repo.Changeset, as: RepoChangeset

  @types %{name: :string, slug: :string, legal_name: :string}

  defp changeset(data \\ %{}) do
    base = %{name: nil, slug: nil, legal_name: nil}
    change({Map.merge(base, data), @types})
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

  describe "validate_json_size/3" do
    defp json_change(value) do
      {%{config: nil}, %{config: :map}} |> change() |> put_change(:config, value)
    end

    test "an unset field passes through" do
      result =
        RepoChangeset.validate_json_size(change({%{config: nil}, %{config: :map}}), :config, 100)

      assert result.valid?
    end

    test "a value within the byte budget passes" do
      assert RepoChangeset.validate_json_size(json_change(%{"a" => "x"}), :config, 100).valid?
    end

    test "a value whose serialized JSON exceeds max_bytes errors on the field" do
      result =
        RepoChangeset.validate_json_size(
          json_change(%{"a" => String.duplicate("x", 200)}),
          :config,
          100
        )

      refute result.valid?
      assert {"is too large (max 100 bytes serialized)", _} = result.errors[:config]
    end
  end
end
