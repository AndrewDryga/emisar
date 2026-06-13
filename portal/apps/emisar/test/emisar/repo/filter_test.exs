defmodule Emisar.Repo.FilterTest do
  @moduledoc """
  `Repo.Filter.validate_value/2` is the type + allowed-value gate every
  LiveTable filter passes through — the boundary where URL-supplied filter
  params are checked before they reach the query, so type confusion can't
  slip in. `merge_dynamic/2` combines the per-filter conditions. Both pure.
  """
  use ExUnit.Case, async: true

  import Ecto.Query, only: [dynamic: 1, dynamic: 2]

  alias Emisar.Repo.Filter
  alias Emisar.Repo.Filter.Range

  defp filter(type, values \\ nil), do: %Filter{name: :x, type: type, values: values}

  describe "validate_value/2 — type checking" do
    test "accepts values matching their declared type" do
      assert :ok = Filter.validate_value(filter(:string), "hello")
      assert :ok = Filter.validate_value(filter(:integer), 42)
      assert :ok = Filter.validate_value(filter(:number), 3.14)
      assert :ok = Filter.validate_value(filter(:boolean), true)
      assert :ok = Filter.validate_value(filter(:date), ~D[2026-01-01])
      assert :ok = Filter.validate_value(filter(:datetime), ~U[2026-01-01 00:00:00Z])
      assert :ok = Filter.validate_value(filter(:datetime), ~N[2026-01-01 00:00:00])
      assert :ok = Filter.validate_value(filter({:string, :email}), "a@b.test")
      assert :ok = Filter.validate_value(filter({:string, :uuid}), Ecto.UUID.generate())
      assert :ok = Filter.validate_value(filter({:list, :integer}), [1, 2, 3])
    end

    test "rejects values whose type doesn't match" do
      assert {:error, {:invalid_type, _}} = Filter.validate_value(filter(:string), 42)
      assert {:error, {:invalid_type, _}} = Filter.validate_value(filter(:integer), "42")
      assert {:error, {:invalid_type, _}} = Filter.validate_value(filter(:boolean), "true")
      assert {:error, {:invalid_type, _}} = Filter.validate_value(filter(:date), "2026-01-01")

      assert {:error, {:invalid_type, _}} =
               Filter.validate_value(filter({:string, :uuid}), "not-a-uuid")

      # A list with a bad element is rejected as a whole.
      assert {:error, {:invalid_type, _}} =
               Filter.validate_value(filter({:list, :integer}), [1, "x"])
    end

    test "a range requires at least one bound, each of the declared type" do
      assert :ok = Filter.validate_value(filter({:range, :integer}), %Range{from: 1, to: 10})
      assert :ok = Filter.validate_value(filter({:range, :integer}), %Range{from: 1, to: nil})

      # Both bounds nil is a meaningless range.
      assert {:error, {:invalid_type, _}} =
               Filter.validate_value(filter({:range, :integer}), %Range{from: nil, to: nil})

      # A bound of the wrong type is rejected.
      assert {:error, {:invalid_type, _}} =
               Filter.validate_value(filter({:range, :integer}), %Range{from: "x", to: nil})
    end
  end

  describe "validate_value/2 — allowed-value lists" do
    test "a flat values list constrains to its members" do
      filter = filter(:integer, [{1, "One"}, {2, "Two"}])
      assert :ok = Filter.validate_value(filter, 1)
      assert {:error, {:invalid_value, _}} = Filter.validate_value(filter, 3)
    end

    test "a grouped values list is searched within each group" do
      filter = filter(:integer, [{"Group A", [{1, "One"}]}, {"Group B", [{2, "Two"}]}])
      assert :ok = Filter.validate_value(filter, 2)
      assert {:error, {:invalid_value, _}} = Filter.validate_value(filter, 9)
    end

    test "no values list means any type-valid value passes" do
      assert :ok = Filter.validate_value(filter(:string, nil), "anything")
      assert :ok = Filter.validate_value(filter(:string, []), "anything")
    end
  end

  describe "merge_dynamic/2" do
    test "a nil operand returns the other side unchanged" do
      condition = dynamic(true)
      assert Filter.merge_dynamic(condition, nil) == condition
      assert Filter.merge_dynamic(nil, condition) == condition
    end

    test "two dynamics are combined conjunctively into a dynamic expression" do
      condition = dynamic(true)
      assert %Ecto.Query.DynamicExpr{} = Filter.merge_dynamic(condition, condition)
    end
  end

  describe "build_dynamic/4 — applying named filters" do
    # `:q` stands in for a queryable; the funs build dynamics without ever
    # running a query, so build_dynamic only collects + merges conditions.
    defp definitions do
      %{
        active: %Filter{name: :active, type: :boolean, fun: fn q -> {q, dynamic(true)} end},
        score: %Filter{
          name: :score,
          type: :integer,
          fun: fn q, value -> {q, dynamic([r], r.score == ^value)} end
        }
      }
    end

    test "an empty filter list leaves the query untouched (nil accumulator)" do
      assert {:q, nil} = Filter.build_dynamic(:q, [], definitions(), nil)
    end

    test "a named filter applies its condition" do
      assert {:q, %Ecto.Query.DynamicExpr{}} =
               Filter.build_dynamic(:q, [{:score, 5}], definitions(), nil)
    end

    test "a boolean false negates the filter's condition" do
      assert {:q, %Ecto.Query.DynamicExpr{}} =
               Filter.build_dynamic(:q, [{:active, false}], definitions(), nil)
    end

    test "an unknown filter name is a clean error" do
      assert {:error, {:unknown_filter, name: :nope}} =
               Filter.build_dynamic(:q, [{:nope, 1}], definitions(), nil)
    end

    test "a type-invalid value is rejected before it reaches the query" do
      assert {:error, {:invalid_type, _}} =
               Filter.build_dynamic(:q, [{:score, "not-an-int"}], definitions(), nil)
    end
  end
end
