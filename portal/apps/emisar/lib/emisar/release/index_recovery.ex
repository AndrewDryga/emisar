defmodule Emisar.Release.IndexRecovery do
  @moduledoc false

  alias Ecto.Adapters.SQL

  # Only the finite, reviewed migration bodies below call this helper. A name
  # alone (including IF NOT EXISTS) proves neither ownership nor a usable index.
  def ensure_index(repo, prefix, table, columns, opts \\ []) do
    spec = specification(table, columns, opts)
    schema = prefix || "public"
    table_oid = verify_table!(repo, schema, spec)

    case index(repo, schema, spec.name) do
      nil -> create_index(repo, schema, spec)
      existing -> repair_index(repo, schema, table_oid, spec, existing)
    end

    existing = index(repo, schema, spec.name)
    verify_index!(repo, table_oid, spec, existing)
    unless usable?(existing), do: refuse!(spec.name, "index is still invalid after recovery")
    clean_remnants(repo, schema, table_oid, spec)
  end

  def drop_index(repo, prefix, table, columns, opts \\ []) do
    spec = specification(table, columns, opts)
    schema = prefix || "public"

    case index(repo, schema, spec.name) do
      nil ->
        :ok

      existing ->
        table_oid = verify_table!(repo, schema, spec)
        verify_index!(repo, table_oid, spec, existing)
        sql(repo, "DROP INDEX CONCURRENTLY #{qualified(schema, spec.name)}")
    end
  end

  def replace_in_flight_index(repo, prefix) do
    opts = [name: "action_runs_in_flight_idx", predicate: :in_flight]
    spec = specification("action_runs", ["status", "queued_at"], opts)
    schema = prefix || "public"

    case index(repo, schema, spec.name) do
      %{"predicate" => predicate} when predicate not in [nil] ->
        if predicate in predicates(:old_in_flight) do
          drop_index(repo, prefix, "action_runs", ["status", "queued_at"],
            name: spec.name,
            predicate: :old_in_flight
          )
        end

      _ ->
        :ok
    end

    ensure_index(repo, prefix, "action_runs", ["status", "queued_at"], opts)
  end

  def ensure_quantity_sync_column(repo, prefix) do
    schema = prefix || "public"
    table = "billing_subscriptions"
    table_oid = table_oid!(repo, schema, table)
    name = "runner_quantity_sync_requested_at"

    case column(repo, table_oid, name) do
      nil ->
        sql(
          repo,
          "ALTER TABLE #{qualified(schema, table)} ADD COLUMN #{quote_name(name)} timestamp"
        )

      existing ->
        unless existing["type"] == "timestamp" and existing["namespace"] == "pg_catalog" and
                 existing["modifier"] == -1 and not existing["not_null"] and
                 not existing["has_default"] and existing["identity"] == "" and
                 existing["generated"] == "" do
          refuse!(name, "existing quantity-sync column has an incompatible shape")
        end
    end
  end

  defp specification(table, columns, opts) do
    keys =
      Enum.map(columns, fn
        {name, order} -> {name, order}
        name -> {name, :asc}
      end)

    %{
      table: table,
      keys: keys,
      name:
        Keyword.get(
          opts,
          :name,
          table <> "_" <> Enum.map_join(keys, "_", &elem(&1, 0)) <> "_index"
        ),
      unique: Keyword.get(opts, :unique, false),
      predicate: Keyword.get(opts, :predicate)
    }
  end

  defp repair_index(repo, schema, table_oid, spec, existing) do
    verify_index!(repo, table_oid, spec, existing)

    unless usable?(existing) do
      # An invalid UNIQUE index may still reject duplicate writes. Rebuild it
      # concurrently rather than dropping that protection before its successor.
      sql(repo, "REINDEX INDEX CONCURRENTLY #{qualified(schema, spec.name)}")
    end
  end

  defp create_index(repo, schema, spec) do
    unique = if spec.unique, do: "UNIQUE ", else: ""

    columns =
      Enum.map_join(spec.keys, ", ", fn {name, order} ->
        quote_name(name) <> order_sql(order)
      end)

    predicate = if spec.predicate, do: " WHERE " <> hd(predicates(spec.predicate)), else: ""

    sql(
      repo,
      "CREATE #{unique}INDEX CONCURRENTLY #{quote_name(spec.name)} ON #{qualified(schema, spec.table)} USING btree (#{columns})#{predicate}"
    )
  end

  defp clean_remnants(repo, schema, table_oid, spec) do
    %{rows: rows} =
      sql(
        repo,
        "SELECT relname FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = $1",
        [schema]
      )

    for [name] <- rows, remnant_name?(name, spec.name) do
      existing = index(repo, schema, name)
      verify_index!(repo, table_oid, spec, existing)
      if existing["valid"], do: refuse!(name, "reindex remnant is valid; ownership is ambiguous")
      sql(repo, "DROP INDEX CONCURRENTLY #{qualified(schema, name)}")
    end
  end

  defp remnant_name?(name, root) do
    case Regex.run(~r/(_cc(?:new|old)(?:[1-9][0-9]*)?)$/, name) do
      [_, suffix] ->
        # PostgreSQL truncates the root again as the numeric retry suffix grows.
        size = min(byte_size(root), 63 - byte_size(suffix))
        size > 0 and name == binary_part(root, 0, size) <> suffix

      nil ->
        false
    end
  end

  defp verify_table!(repo, schema, spec) do
    oid = table_oid!(repo, schema, spec.table)
    names = Enum.uniq(Enum.map(spec.keys, &elem(&1, 0)) ++ predicate_columns(spec.predicate))

    for name <- names do
      unless matching_column?(column(repo, oid, name), column_type(name)) do
        refuse!(spec.name, "unexpected type or collation for #{spec.table}.#{name}")
      end
    end

    oid
  end

  defp table_oid!(repo, schema, table) do
    case sql(
           repo,
           "SELECT c.oid::bigint FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = $1 AND c.relname = $2 AND c.relkind = 'r' AND c.relpersistence = 'p'",
           [schema, table]
         ).rows do
      [[oid]] -> oid
      _ -> refuse!(table, "expected an ordinary permanent table in #{schema}")
    end
  end

  defp column(repo, table_oid, name) do
    query = """
    SELECT jsonb_build_object(
      'type', t.typname, 'namespace', n.nspname, 'modifier', a.atttypmod,
      'not_null', a.attnotnull, 'has_default', a.atthasdef,
      'identity', a.attidentity, 'generated', a.attgenerated,
      'default_collation', a.attcollation = t.typcollation,
      'extension', (SELECT e.extname FROM pg_catalog.pg_depend d
        JOIN pg_catalog.pg_extension e ON e.oid = d.refobjid
        WHERE d.classid = 'pg_catalog.pg_type'::regclass AND d.objid = t.oid
          AND d.refclassid = 'pg_catalog.pg_extension'::regclass AND d.deptype = 'e'))
    FROM pg_catalog.pg_attribute a
    JOIN pg_catalog.pg_type t ON t.oid = a.atttypid
    JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
    WHERE a.attrelid = $1 AND a.attname = $2 AND a.attnum > 0 AND NOT a.attisdropped
    """

    case sql(repo, query, [table_oid, name]).rows do
      [[value]] -> value
      [] -> nil
    end
  end

  defp matching_column?(nil, _type), do: false

  defp matching_column?(column, type) do
    namespace? =
      if type == "citext",
        do: column["extension"] == "citext",
        else: column["namespace"] == "pg_catalog"

    modifier? = if type == "varchar", do: column["modifier"] == 259, else: true
    column["type"] == type and namespace? and modifier? and column["default_collation"]
  end

  defp column_type(name)
       when name in ~w(status actor_kind target_kind action_id pack_id pack_version provider_identifier external_group_id paddle_customer_id),
       do: "varchar"

  defp column_type("allowed_email_domain"), do: "citext"
  defp column_type("inputs_raw"), do: "bytea"
  defp column_type("enabled"), do: "bool"

  defp column_type(name) do
    if String.ends_with?(name, "_at"), do: "timestamp", else: "uuid"
  end

  defp index(repo, schema, name) do
    query = """
    SELECT jsonb_build_object(
      'oid', c.oid::bigint, 'table_oid', i.indrelid::bigint,
      'kind', c.relkind, 'persistence', c.relpersistence,
      'method', am.amname, 'unique', i.indisunique,
      'valid', i.indisvalid, 'ready', i.indisready, 'live', i.indislive,
      'plain', i.indexprs IS NULL AND i.indnkeyatts = i.indnatts,
      'ordinary', NOT i.indisprimary AND NOT i.indisexclusion AND NOT i.indisreplident
        AND NOT i.indisclustered AND i.indimmediate AND NOT i.indnullsnotdistinct,
      'options', c.reloptions IS NULL AND c.reltablespace = 0,
      'predicate', pg_catalog.pg_get_expr(i.indpred, i.indrelid, false),
      'dependency_columns', (SELECT jsonb_agg(DISTINCT a.attname ORDER BY a.attname)
        FROM pg_catalog.pg_depend d JOIN pg_catalog.pg_attribute a
          ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
        WHERE d.classid = 'pg_catalog.pg_class'::regclass AND d.objid = c.oid
          AND d.refclassid = 'pg_catalog.pg_class'::regclass AND d.refobjid = i.indrelid),
      'keys', (SELECT jsonb_agg(jsonb_build_object(
        'name', a.attname, 'order', i.indoption[k],
        'default', opc.opcdefault AND opc.opcmethod = c.relam
          AND opc.opcname = CASE t.typname WHEN 'varchar' THEN 'text_ops' ELSE t.typname || '_ops' END
          AND opc.opcintype = CASE t.typname WHEN 'varchar' THEN 'pg_catalog.text'::regtype ELSE t.oid END
          AND ((t.typname <> 'citext' AND ons.nspname = 'pg_catalog') OR (t.typname = 'citext' AND EXISTS (
            SELECT 1 FROM pg_catalog.pg_depend td JOIN pg_catalog.pg_depend od ON od.refobjid = td.refobjid
            JOIN pg_catalog.pg_extension e ON e.oid = td.refobjid AND e.extname = 'citext'
            WHERE td.classid = 'pg_catalog.pg_type'::regclass AND td.objid = t.oid AND td.deptype = 'e'
              AND td.refclassid = 'pg_catalog.pg_extension'::regclass
              AND od.classid = 'pg_catalog.pg_opclass'::regclass AND od.objid = opc.oid AND od.deptype = 'e'
              AND od.refclassid = 'pg_catalog.pg_extension'::regclass)))
          AND i.indcollation[k] = a.attcollation AND ia.attoptions IS NULL)
        ORDER BY k)
        FROM generate_series(0, i.indnkeyatts - 1) k
        LEFT JOIN pg_catalog.pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[k] AND a.attnum > 0
        LEFT JOIN pg_catalog.pg_attribute ia ON ia.attrelid = c.oid AND ia.attnum = k + 1
        LEFT JOIN pg_catalog.pg_type t ON t.oid = a.atttypid
        LEFT JOIN pg_catalog.pg_opclass opc ON opc.oid = i.indclass[k]
        LEFT JOIN pg_catalog.pg_namespace ons ON ons.oid = opc.opcnamespace),
      'dependencies', NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint WHERE conindid = c.oid)
        AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_depend d
          WHERE d.refclassid = 'pg_catalog.pg_class'::regclass AND d.refobjid = c.oid)
        AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_depend d
          WHERE d.classid = 'pg_catalog.pg_class'::regclass AND d.objid = c.oid
            AND NOT ((d.deptype = 'a' AND d.objsubid = 0
              AND d.refclassid = 'pg_catalog.pg_class'::regclass AND d.refobjid = i.indrelid
              AND d.refobjsubid > 0)
            OR (d.deptype = 'n' AND d.objsubid = 0
              AND d.refclassid = 'pg_catalog.pg_opclass'::regclass AND d.refobjid = ANY(i.indclass)))))
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_catalog.pg_index i ON i.indexrelid = c.oid
    LEFT JOIN pg_catalog.pg_am am ON am.oid = c.relam
    WHERE n.nspname = $1 AND c.relname = $2
    """

    case sql(repo, query, [schema, name]).rows do
      [[value]] -> value
      [] -> nil
    end
  end

  defp verify_index!(_repo, table_oid, spec, existing) do
    keys =
      Enum.map(spec.keys, fn {name, order} ->
        %{"name" => name, "order" => order_option(order), "default" => true}
      end)

    dependencies =
      Enum.sort(Enum.uniq(Enum.map(spec.keys, &elem(&1, 0)) ++ predicate_columns(spec.predicate)))

    unless existing && existing["table_oid"] == table_oid && existing["kind"] == "i" &&
             existing["persistence"] == "p" && existing["method"] == "btree" &&
             existing["unique"] == spec.unique && existing["plain"] && existing["ordinary"] &&
             existing["options"] && existing["dependencies"] && existing["keys"] == keys &&
             existing["dependency_columns"] == dependencies &&
             existing["predicate"] in predicates(spec.predicate) do
      refuse!(spec.name, "existing relation does not match the owned index definition")
    end
  end

  defp usable?(existing), do: existing["valid"] and existing["ready"] and existing["live"]
  defp order_option(:asc), do: 0
  defp order_option(:desc), do: 3
  defp order_option(:asc_nulls_first), do: 2
  defp order_sql(:asc), do: " ASC"
  defp order_sql(:desc), do: " DESC"
  defp order_sql(:asc_nulls_first), do: " ASC NULLS FIRST"

  defp predicates(nil), do: [nil]
  defp predicates(:deleted), do: ["(deleted_at IS NOT NULL)"]
  defp predicates(:not_deleted), do: ["(deleted_at IS NULL)"]
  defp predicates(:finished), do: ["(finished_at IS NOT NULL)"]
  defp predicates(:completed), do: ["(completed_at IS NOT NULL)"]
  defp predicates(:quantity_sync), do: ["(runner_quantity_sync_requested_at IS NOT NULL)"]
  defp predicates(:active), do: ["((status)::text = 'active'::text)"]
  defp predicates(:running), do: ["((status)::text = 'running'::text)"]

  defp predicates(:active_identifier),
    do: ["((deleted_at IS NULL) AND (provider_identifier_retired_at IS NULL))"]

  defp predicates(:email_domain),
    do: ["(enabled AND (deleted_at IS NULL) AND (allowed_email_domain IS NOT NULL))"]

  defp predicates(:customer_sync),
    do: [
      "((deleted_at IS NULL) AND ((paddle_customer_id IS NULL) OR (paddle_billing_contact_user_id IS NULL) OR (paddle_customer_synced_at IS NULL) OR (updated_at > paddle_customer_synced_at)))"
    ]

  defp predicates(:old_in_flight), do: status_predicates(~w(pending sent running))
  defp predicates(:in_flight), do: status_predicates(~w(pending sent running cancelling))

  defp predicates(:unscrubbed) do
    Enum.map(
      status_predicates(~w(succeeded halted cancelled)),
      &"(#{&1} AND (inputs_raw IS NOT NULL))"
    )
  end

  # These are finite authored status lists, not normalization of catalog SQL.
  # PostgreSQL's original DDL and dump/restore spellings differ in their casts.
  defp status_predicates(values) do
    text = Enum.map_join(values, ", ", &"'#{&1}'::text")
    varchar = Enum.map_join(values, ", ", &"'#{&1}'::character varying")
    cast = Enum.map_join(values, ", ", &"('#{&1}'::character varying)::text")

    [
      "((status)::text = ANY (ARRAY[#{text}]))",
      "((status)::text = ANY ((ARRAY[#{varchar}])::text[]))",
      "((status)::text = ANY (ARRAY[#{cast}]))"
    ]
  end

  defp predicate_columns(nil), do: []
  defp predicate_columns(predicate) when predicate in [:deleted, :not_deleted], do: ["deleted_at"]
  defp predicate_columns(:finished), do: ["finished_at"]
  defp predicate_columns(:completed), do: ["completed_at"]
  defp predicate_columns(:quantity_sync), do: ["runner_quantity_sync_requested_at"]

  defp predicate_columns(predicate)
       when predicate in [:active, :running, :old_in_flight, :in_flight], do: ["status"]

  defp predicate_columns(:unscrubbed), do: ["status", "inputs_raw"]
  defp predicate_columns(:active_identifier), do: ["deleted_at", "provider_identifier_retired_at"]
  defp predicate_columns(:email_domain), do: ["enabled", "deleted_at", "allowed_email_domain"]

  defp predicate_columns(:customer_sync) do
    ~w(deleted_at paddle_customer_id paddle_billing_contact_user_id paddle_customer_synced_at updated_at)
  end

  defp quote_name(name), do: "\"" <> String.replace(name, "\"", "\"\"") <> "\""
  defp qualified(schema, name), do: quote_name(schema) <> "." <> quote_name(name)

  defp sql(repo, statement, params \\ []),
    do: SQL.query!(repo, statement, params, timeout: :infinity)

  defp refuse!(name, reason), do: raise("Concurrent index recovery refused #{name}: #{reason}")
end
