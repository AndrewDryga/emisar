defmodule Emisar.Repo.CursorFieldsTest do
  @moduledoc """
  Authoring-time lint: every `cursor_fields/0` entry names a `NOT NULL` column.

  `Paginator.encode_cursor/3` reads each cursor field with `Map.fetch!/2` and
  hands it to `encode_value/1`, whose last clause raises on a value it has no
  tag for — `nil` included. A nil-tolerant encoder would be worse, not better:
  the keyset predicate is `col > NULL`, which is NULL, so the page after a nil
  boundary comes back empty and the tail of the list silently disappears. The
  raise is the right runtime behaviour; this is the check that stops the
  declaration from being written, which is where the problem is fixable.

  `SSO.DirectoryGroup.Query` declared exactly that — `external_group_id` stopped
  being `NOT NULL` in `20260927000000` — and nothing noticed because
  `Repo.list/3` never reached it.
  """
  use Emisar.DataCase, async: true

  test "every declared cursor field is NOT NULL on the rows a list can reach" do
    nullable =
      for {query_module, cursor_fields} <- cursor_field_declarations(),
          {_binding, _order, field} <- cursor_fields,
          {table, column} = table_and_column(query_module, field),
          nullable_column?(table, column),
          not live_rows_not_null?(table, column),
          do: "#{inspect(query_module)} → #{table}.#{column}"

    assert nullable == []
  end

  defp cursor_field_declarations do
    {:ok, modules} = :application.get_key(:emisar, :modules)

    for module <- modules,
        Code.ensure_loaded?(module),
        function_exported?(module, :cursor_fields, 0),
        do: {module, module.cursor_fields()}
  end

  defp table_and_column(query_module, field) do
    # `safe_concat` because the schema is already loaded — a query module whose
    # schema is not is itself the finding, not a reason to mint an atom.
    schema = query_module |> Module.split() |> Enum.drop(-1) |> Module.safe_concat()

    assert function_exported?(schema, :__schema__, 1),
           "#{inspect(query_module)} declares cursor_fields/0 but #{inspect(schema)} is not a schema"

    {schema.__schema__(:source), schema.__schema__(:field_source, field)}
  end

  defp nullable_column?(table, column) do
    query = """
    SELECT is_nullable
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2
    """

    case Repo.query!(query, [table, Atom.to_string(column)]) do
      %{rows: [["YES"]]} -> true
      %{rows: [["NO"]]} -> false
      %{rows: []} -> flunk("cursor field #{table}.#{column} does not exist")
    end
  end

  # A soft-delete table may leave a column nullable for TOMBSTONES while a CHECK
  # requires it on every live row — `sso_directory_group_role_mappings` does. Every
  # list pipeline starts at `not_deleted/1` (AGENTS.md §2), so such a column cannot
  # reach a cursor as nil. Read the constraint rather than keep a second hand list:
  # dropping the CHECK must make this fire.
  defp live_rows_not_null?(table, column) do
    query = """
    SELECT pg_get_constraintdef(oid)
    FROM pg_constraint
    WHERE contype = 'c' AND conrelid = to_regclass($1)
    """

    %{rows: rows} = Repo.query!(query, [table])

    Enum.any?(rows, fn [definition] ->
      String.contains?(definition, "deleted_at IS NOT NULL") and
        String.contains?(definition, "#{column} IS NOT NULL")
    end)
  end
end
