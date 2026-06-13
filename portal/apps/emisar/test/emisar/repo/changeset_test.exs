defmodule Emisar.Repo.ChangesetTest do
  @moduledoc """
  `Repo.Changeset.put_default_value/3` — the shared "fill this field only if
  it's unset" helper. Each context hits just one value-form, so the literal,
  lazy 0-arity fn, changeset-aware 1-arity fn, and copy-from-another-field
  forms are exercised together here. Schemaless changesets keep it pure.
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
end
