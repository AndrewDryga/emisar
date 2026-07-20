defmodule EmisarWeb.MCP.CatalogTools do
  @moduledoc """
  Fixed MCP catalog tool implementation.

  Authorization and account isolation come from the domain contexts. This
  module additionally applies the API key creator's runner scope, projects
  hostile runner advertisements through exact-hash trusted manifests, and
  shapes bounded model-facing responses.
  """

  alias Emisar.{Catalog, Crypto, Runners}
  alias EmisarWeb.MCP.{CatalogCursor, ToolSchema}

  @default_limit 15
  @max_search_score 9_999
  @max_page_items_bytes 60_000

  defmodule ListPacksArgs do
    @moduledoc false
    defstruct pack_id: nil,
              pack_ref: nil,
              runner_refs: [],
              availability: "executable",
              limit: 15,
              cursor: nil
  end

  defmodule ListRunnersArgs do
    @moduledoc false
    defstruct query: nil,
              runner_refs: [],
              statuses: [],
              pack_id: nil,
              pack_ref: nil,
              action_id: nil,
              issues_only: false,
              limit: 15,
              cursor: nil
  end

  defmodule FindActionsArgs do
    @moduledoc false
    defstruct query: nil,
              action_id: nil,
              pack_id: nil,
              pack_ref: nil,
              target: nil,
              runner_refs: [],
              limit: 15,
              cursor: nil
  end

  defmodule GetActionArgs do
    @moduledoc false
    defstruct action_id: nil, pack_ref: nil, target: nil, runner_refs: []
  end

  @doc "Executes one of the four fixed, read-only catalog tools."
  @spec call(Plug.Conn.t(), String.t(), map()) :: {:ok, map()} | {:error, map()}
  def call(conn, tool, args) when tool in ~w(list_packs list_runners find_actions get_action) do
    with {:ok, snapshot, scope} <- snapshot(conn) do
      execute(tool, snapshot, scope, parse(tool, args), conn)
    end
  end

  defp snapshot(conn) do
    subject = conn.assigns.current_subject
    api_key = conn.assigns.api_key

    with {:ok, runners} <- Runners.list_all_runners_for_account(subject),
         {:ok, actions} <- Catalog.list_all_actions_for_account(subject),
         {:ok, pack_versions} <- Catalog.list_all_pack_versions_for_account(subject) do
      runner_ids = MapSet.new(runners, & &1.id)
      actions = Enum.filter(actions, &MapSet.member?(runner_ids, &1.runner_id))
      snapshot = Catalog.MCPProjection.build(pack_versions, actions, runners)

      scope =
        [subject.account.id, api_key.id | Enum.map(snapshot.runners, & &1.runner_ref)]
        |> Enum.join("\0")
        |> Crypto.hash_hex()

      {:ok, snapshot, scope}
    else
      {:error, :unauthorized} ->
        {:error, error("not_allowed", "This key cannot read catalog data.")}
    end
  end

  defp execute("list_packs", snapshot, scope, args, _conn) do
    packs =
      snapshot.packs
      |> Enum.filter(&pack_matches?(&1, args))
      |> Enum.map(&pack_result(&1, args))
      |> Enum.reject(&is_nil/1)

    paginate(
      "list_packs",
      packs,
      & &1.pack_ref,
      scope,
      args,
      :packs
    )
  end

  defp execute("list_runners", snapshot, scope, args, _conn) do
    packs_by_ref = Map.new(snapshot.packs, &{&1.pack_ref, &1})

    runners =
      snapshot.runners
      |> Enum.filter(&runner_matches?(&1, packs_by_ref, args))

    summary = runner_summary(runners)

    with {:ok, page} <-
           paginate(
             "list_runners",
             runners,
             & &1.runner_ref,
             scope,
             args,
             :runners,
             &runner_result/1
           ) do
      {:ok, Map.put(page, :summary, summary)}
    end
  end

  defp execute("find_actions", snapshot, scope, args, _conn) do
    candidates =
      snapshot.packs
      |> Enum.flat_map(&searchable_actions(&1, snapshot.runners, args))
      |> Enum.map(&score_candidate(&1, args))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(&{-&1.score, &1.action["action_id"], &1.pack_ref})

    paginate(
      "find_actions",
      candidates,
      &search_key/1,
      scope,
      args,
      :candidates,
      &candidate_result/1
    )
  end

  defp execute("get_action", snapshot, _scope, args, _conn) do
    with %{} = pack <- Enum.find(snapshot.packs, &(&1.pack_ref == args.pack_ref)),
         %{} = action <- Enum.find(pack.actions, &(&1["action_id"] == args.action_id)),
         runners when runners != [] <- compatible_runners(snapshot.runners, action, args) do
      runner_limit = if args.runner_refs == [], do: @default_limit, else: length(args.runner_refs)
      {runners, more?} = split_more(runners, runner_limit)

      {:ok,
       %{
         ok: true,
         observed_at: observed_at(),
         action:
           %{
             action_id: action["action_id"],
             pack_ref: pack.pack_ref,
             title: action["title"],
             description: action["description"],
             risk: action["risk"],
             side_effects: action["side_effects"],
             args_schema: ToolSchema.action_args_schema(action),
             examples: action["examples"]
           }
           |> maybe_put_output_schema(action["output_schema"]),
         compatible_runners: Enum.map(runners, &runner_brief/1),
         more_compatible_runners: more?,
         next: compatible_runners_next(pack, action, args, more?)
       }}
    else
      _other ->
        payload =
          error(
            "action_unavailable",
            "No in-scope connected runner can execute this exact trusted action."
          )

        next = %{
          tool: "list_runners",
          arguments: %{pack_ref: args.pack_ref, action_id: args.action_id, limit: 15}
        }

        {:error, put_in(payload, [:error, :next], next)}
    end
  end

  defp maybe_put_output_schema(action, %{} = schema), do: Map.put(action, :output_schema, schema)
  defp maybe_put_output_schema(action, _schema), do: action

  defp pack_matches?(pack, args) do
    (is_nil(args.pack_id) or pack.pack_id == args.pack_id) and
      (is_nil(args.pack_ref) or pack.pack_ref == args.pack_ref) and
      runner_ref_overlap?(Map.values(pack.compatibility), args.runner_refs)
  end

  defp pack_result(pack, args) do
    selected_runner_ids = selected_runner_ids(pack, args.runner_refs)

    actions =
      pack.actions
      |> Enum.map(fn action ->
        action_availability =
          if Enum.any?(action.compatible_runner_ids, &MapSet.member?(selected_runner_ids, &1)),
            do: "executable",
            else: "unavailable"

        if args.availability == "all" or action_availability == "executable" do
          %{
            action_id: action["action_id"],
            title: action["title"],
            summary: action["summary"],
            risk: action["risk"],
            availability: action_availability
          }
        end
      end)
      |> Enum.reject(&is_nil/1)

    pack_availability =
      if Enum.any?(actions, &(&1.availability == "executable")),
        do: "executable",
        else: "unavailable"

    if args.availability == "all" or pack_availability == "executable" do
      %{
        pack_ref: pack.pack_ref,
        availability: pack_availability,
        issues: pack.issues,
        actions: actions
      }
    end
  end

  defp selected_runner_ids(pack, []) do
    pack.compatibility |> Map.keys() |> MapSet.new()
  end

  defp selected_runner_ids(pack, runner_refs) do
    pack.compatibility
    |> Enum.filter(fn {_runner_id, compatibility} ->
      compatibility.runner_ref in runner_refs
    end)
    |> Enum.map(fn {runner_id, _compatibility} -> runner_id end)
    |> MapSet.new()
  end

  defp runner_matches?(runner, packs_by_ref, args) do
    (is_nil(args.query) or runner_query_match?(runner, args.query)) and
      (args.runner_refs == [] or runner.runner_ref in args.runner_refs) and
      (args.statuses == [] or runner.status in args.statuses) and
      (not args.issues_only or runner.issues != []) and
      runner_pack_match?(runner, packs_by_ref, args)
  end

  defp runner_pack_match?(_runner, _packs, %{pack_id: nil, pack_ref: nil}), do: true

  defp runner_pack_match?(runner, packs_by_ref, args) do
    Enum.any?(packs_by_ref, fn {_pack_ref, pack} ->
      # A pack the runner has no compatibility entry for is simply not a match —
      # guard nil explicitly. The old `compatibility && (...)` returned nil, which
      # `and` then rejected with a BadBooleanError, crashing the filter.
      case Map.get(pack.compatibility, runner.id) do
        nil ->
          false

        compatibility ->
          (is_nil(args.pack_id) or pack.pack_id == args.pack_id) and
            (is_nil(args.pack_ref) or pack.pack_ref == args.pack_ref) and
            (is_nil(args.action_id) or args.action_id in compatibility.compatible_action_ids)
      end
    end)
  end

  defp runner_query_match?(runner, query) do
    query = String.downcase(query)

    [
      runner.name,
      runner.hostname,
      runner.group | Map.keys(runner.labels) ++ Map.values(runner.labels)
    ]
    |> Enum.any?(&String.contains?(String.downcase(&1), query))
  end

  defp runner_result(runner) do
    runner
    |> runner_brief()
    |> Map.merge(%{
      last_seen_at: runner.last_seen_at,
      labels: runner.labels,
      packs_next: %{
        tool: "list_packs",
        arguments: %{runner_refs: [runner.runner_ref], availability: "all", limit: @default_limit}
      },
      issues: runner.issues
    })
  end

  defp runner_summary(runners) do
    Enum.reduce(
      runners,
      %{matched: length(runners), connected: 0, disconnected: 0, pending: 0, disabled: 0},
      fn runner, acc ->
        Map.update!(acc, String.to_existing_atom(runner.status), &(&1 + 1))
      end
    )
  end

  defp searchable_actions(pack, runners, args) do
    if (is_nil(args.pack_id) or pack.pack_id == args.pack_id) and
         (is_nil(args.pack_ref) or pack.pack_ref == args.pack_ref) do
      Enum.flat_map(pack.actions, fn action ->
        compatible = compatible_runners(runners, action, args)

        if compatible == [] do
          []
        else
          [%{action: action, pack_ref: pack.pack_ref}]
        end
      end)
    else
      []
    end
  end

  defp score_candidate(candidate, %{action_id: action_id}) when is_binary(action_id) do
    if candidate.action["action_id"] == action_id,
      do: Map.merge(candidate, %{score: 10_000, matched_fields: ["action_id"]})
  end

  defp score_candidate(candidate, %{query: nil}),
    do: Map.merge(candidate, %{score: 1, matched_fields: []})

  defp score_candidate(candidate, %{query: query}) do
    query = query |> String.downcase() |> String.trim()
    action = candidate.action
    id = String.downcase(action["action_id"])
    title = String.downcase(action["title"])
    summary = String.downcase(action["summary"])
    terms = Enum.map(action["search_terms"], &String.downcase/1)
    tokens = query |> String.split() |> Enum.uniq()
    {term_score, term_fields} = score_query_terms(tokens, id, title, summary, terms)

    {score, fields} =
      cond do
        id == query ->
          {10_000, ["action_id"]}

        String.starts_with?(id, query) ->
          {8_000, ["action_id"]}

        title == query ->
          {7_000, ["title"]}

        query in terms ->
          {6_000, ["search_terms"]}

        length(tokens) == 1 and Enum.all?(tokens, &String.contains?(id, &1)) ->
          {5_000, ["action_id"]}

        length(tokens) == 1 and Enum.all?(tokens, &String.contains?(title, &1)) ->
          {4_000, ["title"]}

        length(tokens) == 1 and
            Enum.all?(tokens, fn token ->
              String.contains?(summary, token) or Enum.any?(terms, &String.contains?(&1, token))
            end) ->
          {3_000, ["summary", "search_terms"]}

        length(tokens) > 1 and term_score > 0 ->
          {term_score, term_fields}

        String.jaro_distance(query, id) >= 0.88 ->
          {2_000, ["action_id"]}

        String.jaro_distance(query, title) >= 0.9 ->
          {1_000, ["title"]}

        true ->
          {0, []}
      end

    if score > 0, do: Map.merge(candidate, %{score: score, matched_fields: fields})
  end

  defp score_query_terms(tokens, id, title, summary, terms) do
    matched_fields_by_term = Enum.map(tokens, &matching_fields(&1, id, title, summary, terms))
    matched_fields = Enum.reject(matched_fields_by_term, &(&1 == []))

    if matched_fields == [] do
      {0, []}
    else
      score =
        min(
          @max_search_score,
          3_000 +
            length(matched_fields) * 1_000 +
            Enum.count(matched_fields, &("action_id" in &1)) * 300 +
            Enum.count(matched_fields, &("title" in &1)) * 200 +
            Enum.count(matched_fields, &("summary" in &1 or "search_terms" in &1)) * 100
        )

      fields = matched_fields_by_term |> List.flatten() |> Enum.uniq()
      {score, fields}
    end
  end

  defp matching_fields(token, id, title, summary, terms) do
    [
      {"action_id", String.contains?(id, token)},
      {"title", String.contains?(title, token)},
      {"summary", String.contains?(summary, token)},
      {"search_terms", Enum.any?(terms, &String.contains?(&1, token))}
    ]
    |> Enum.filter(fn {_field, matched?} -> matched? end)
    |> Enum.map(&elem(&1, 0))
  end

  defp candidate_result(candidate) do
    action = candidate.action

    %{
      action_id: action["action_id"],
      pack_ref: candidate.pack_ref,
      title: action["title"],
      summary: action["summary"],
      risk: action["risk"],
      side_effects: action["side_effects"],
      matched_fields: candidate.matched_fields,
      next: %{
        tool: "get_action",
        arguments: %{action_id: action["action_id"], pack_ref: candidate.pack_ref}
      }
    }
  end

  defp compatible_runners(runners, action, args) do
    Enum.filter(runners, fn runner ->
      runner.id in action.compatible_runner_ids and
        (Map.get(args, :runner_refs, []) == [] or runner.runner_ref in args.runner_refs) and
        (is_nil(Map.get(args, :target)) or runner_query_match?(runner, args.target))
    end)
    |> Enum.sort_by(& &1.runner_ref)
  end

  defp compatible_runners_next(_pack, _action, _args, false), do: nil

  defp compatible_runners_next(pack, action, args, true) do
    arguments = %{pack_ref: pack.pack_ref, action_id: action["action_id"], limit: @default_limit}
    arguments = if args.target, do: Map.put(arguments, :query, args.target), else: arguments

    %{tool: "list_runners", arguments: arguments}
  end

  defp runner_brief(runner) do
    %{
      runner_ref: runner.runner_ref,
      name: runner.name,
      hostname: runner.hostname,
      group: runner.group,
      enforce_signatures: runner.enforce_signatures,
      status: runner.status
    }
  end

  defp runner_ref_overlap?(_compatibilities, []), do: true

  defp runner_ref_overlap?(compatibilities, runner_refs) do
    Enum.any?(compatibilities, &(&1.runner_ref in runner_refs))
  end

  defp paginate(tool, items, key, scope, args, field, render \\ & &1) do
    filters = cursor_filters(args)

    case CatalogCursor.decode(args.cursor, tool, scope, filters) do
      {:ok, last_key} ->
        items = if last_key, do: Enum.drop_while(items, &(key.(&1) <= last_key)), else: items
        {page, more?} = split_more(items, args.limit)
        {page, rendered, more?} = fit_page(page, render, more?)

        cursor =
          if more? do
            CatalogCursor.encode(tool, scope, filters, key.(List.last(page)))
          end

        result =
          Map.merge(%{ok: true, observed_at: observed_at()}, pagination(tool, args, cursor))

        {:ok, Map.put(result, field, rendered)}

      {:error, :invalid_cursor} ->
        {:error,
         error("invalid_cursor", "The cursor is invalid, expired, or belongs to another query.")}
    end
  end

  # find_actions hands back the whole next page as a copy-ready `next`
  # continuation (the model must re-supply the query with the cursor, so a bare
  # cursor is not enough); the other paginated reads keep their `next_cursor`.
  defp pagination("find_actions", args, cursor), do: %{next: find_actions_next(args, cursor)}
  defp pagination(_tool, _args, cursor), do: %{next_cursor: cursor}

  defp find_actions_next(_args, nil), do: nil

  defp find_actions_next(args, cursor) do
    search =
      args
      |> Map.take([:query, :action_id, :pack_id, :pack_ref, :target, :runner_refs])
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == [] end)
      |> Map.new()

    %{tool: "find_actions", arguments: Map.put(search, :cursor, cursor)}
  end

  defp split_more(items, limit) do
    page = Enum.take(items, limit + 1)
    {Enum.take(page, limit), length(page) > limit}
  end

  defp fit_page(page, render, more?) do
    rendered = Enum.map(page, render)

    if byte_size(Jason.encode!(rendered)) <= @max_page_items_bytes or length(page) <= 1 do
      {page, rendered, more?}
    else
      page |> Enum.drop(-1) |> fit_page(render, true)
    end
  end

  defp search_key(candidate) do
    String.pad_leading(Integer.to_string(10_000 - candidate.score), 5, "0") <>
      "\0" <> candidate.action["action_id"] <> "\0" <> candidate.pack_ref
  end

  defp observed_at, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp cursor_filters(args) do
    args
    |> Map.from_struct()
    |> Map.drop([:cursor, :limit])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  # The controller already validated `args` against each tool's published
  # inputSchema; these builders only apply the documented defaults.
  defp parse("list_packs", args) do
    %__MODULE__.ListPacksArgs{
      pack_id: args["pack_id"],
      pack_ref: args["pack_ref"],
      runner_refs: args["runner_refs"] || [],
      availability: args["availability"] || "executable",
      limit: args["limit"] || @default_limit,
      cursor: args["cursor"]
    }
  end

  defp parse("list_runners", args) do
    %__MODULE__.ListRunnersArgs{
      query: args["query"],
      runner_refs: args["runner_refs"] || [],
      statuses: args["statuses"] || [],
      pack_id: args["pack_id"],
      pack_ref: args["pack_ref"],
      action_id: args["action_id"],
      issues_only: args["issues_only"] || false,
      limit: args["limit"] || @default_limit,
      cursor: args["cursor"]
    }
  end

  defp parse("find_actions", args) do
    %__MODULE__.FindActionsArgs{
      query: args["query"],
      action_id: args["action_id"],
      pack_id: args["pack_id"],
      pack_ref: args["pack_ref"],
      target: args["target"],
      runner_refs: args["runner_refs"] || [],
      limit: args["limit"] || @default_limit,
      cursor: args["cursor"]
    }
  end

  defp parse("get_action", args) do
    %__MODULE__.GetActionArgs{
      action_id: args["action_id"],
      pack_ref: args["pack_ref"],
      target: args["target"],
      runner_refs: args["runner_refs"] || []
    }
  end

  defp error(code, message) do
    %{
      ok: false,
      error: %{code: code, message: message, retryable: false},
      dispatch_started: false
    }
  end
end
