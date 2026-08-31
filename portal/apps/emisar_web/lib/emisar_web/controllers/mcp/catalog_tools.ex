defmodule EmisarWeb.MCP.CatalogTools do
  @moduledoc """
  Fixed MCP catalog tool implementation.

  `Emisar.Catalog` owns authorization, account isolation, the caller's runner
  scope, and the exact-hash trusted projection of hostile runner
  advertisements. This module only filters, ranks, paginates, and shapes
  bounded model-facing responses over that snapshot.
  """

  alias Emisar.{Catalog, Crypto}
  alias EmisarWeb.MCP.{CatalogCursor, Service, ToolSchema}

  @default_limit 15
  @max_search_score 9_999
  @max_page_items_bytes 60_000

  defmodule ListPacksArgs do
    @moduledoc false
    defstruct pack_id: nil,
              pack_ref: nil,
              runner_refs: [],
              # `include` is the caller's FILTER MODE. It is deliberately not
              # called `availability`, which is the STATE each returned pack and
              # action carries: one name with two disjoint value spaces meant a
              # model could read `unavailable` from a response and not pass it
              # back, and there was no way to ask for only the broken ones —
              # the diagnostic query operators actually have.
              include: "executable",
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
  def call(conn, "get_action", args) do
    get_action(conn.assigns.current_subject, parse("get_action", args))
  end

  def call(conn, tool, args) when tool in ~w(list_packs list_runners find_actions) do
    with {:ok, snapshot, scope} <- snapshot(conn) do
      execute(tool, snapshot, scope, parse(tool, args))
    end
  end

  defp snapshot(conn) do
    subject = conn.assigns.current_subject
    api_key = conn.assigns.api_key

    case Catalog.model_catalog(subject) do
      {:ok, snapshot} ->
        scope =
          [subject.account.id, api_key.id] ++
            Enum.map(snapshot.runners, & &1.runner_ref) ++
            Enum.map(snapshot.packs, & &1.pack_ref)

        scope =
          scope
          |> Enum.join("\0")
          |> Crypto.hash_hex()

        {:ok, snapshot, scope}

      {:error, :unauthorized} ->
        {:error, error("not_allowed", "This key cannot read catalog data.")}
    end
  end

  defp execute("list_packs", snapshot, scope, args) do
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

  defp execute("list_runners", snapshot, scope, args) do
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
             &runner_result(&1, snapshot.packs)
           ) do
      {:ok, Map.put(page, :summary, summary)}
    end
  end

  defp execute("find_actions", snapshot, scope, args) do
    searchable =
      snapshot.packs
      |> Enum.flat_map(&searchable_actions(&1, snapshot.runners, args))
      |> Enum.map(&put_search_words/1)

    weights = token_weights(args, searchable)

    candidates =
      searchable
      |> Enum.map(&score_candidate(&1, args, weights))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(&{-&1.score, &1.action["action_id"], &1.pack_ref})
      |> cover_query_concepts()
      |> Enum.with_index(fn candidate, rank -> Map.put(candidate, :rank, rank) end)

    if candidates == [] and exact_action_filter?(args) do
      case deployed_pack_ref(snapshot, args) do
        nil -> paginate_candidates(candidates, scope, args)
        pack_ref -> unavailable_action_error(args, pack_ref)
      end
    else
      paginate_candidates(candidates, scope, args)
    end
  end

  # An empty `runner_refs` asks for every compatible runner; an explicit list is
  # all-or-nothing, and the domain fails it closed. `target` is the model's
  # free-text narrowing over what already resolved, so it stays here.
  defp get_action(subject, args) do
    with {:ok, resolved} <-
           Catalog.resolve_model_action(args.action_id, args.pack_ref, args.runner_refs, subject),
         runners = target_matches(resolved.runners, args.target),
         [_runner | _rest] <- runners do
      runner_limit = if args.runner_refs == [], do: @default_limit, else: length(args.runner_refs)
      {runners, more?} = split_more(runners, runner_limit)
      action = resolved.action

      {:ok,
       %{
         ok: true,
         observed_at: observed_at(),
         action:
           %{
             action_id: action["action_id"],
             pack_ref: resolved.pack.pack_ref,
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
         next: compatible_runners_next(resolved.pack, action, args, more?)
       }}
    else
      {:error, :unauthorized} ->
        {:error, error("not_allowed", "This key cannot read catalog data.")}

      _unavailable ->
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

  defp target_matches(runners, nil), do: runners

  defp target_matches(runners, target),
    do: Enum.filter(runners, &runner_query_match?(&1, target))

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

        if include_deployment?(args.include, action_availability) do
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

    if include_deployment?(args.include, pack_availability) do
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

  defp runner_result(runner, packs) do
    runner
    |> runner_brief()
    |> Map.merge(%{
      last_seen_at: runner.last_seen_at,
      labels: runner.labels,
      packs: dispatchable_pack_ids(runner, packs),
      packs_next: %{
        tool: "list_packs",
        arguments: %{runner_refs: [runner.runner_ref], include: "all", limit: @default_limit}
      },
      issues: runner.issues
    })
  end

  # Bare pack ids the portal could dispatch on this runner right now — a trusted,
  # descriptor-matched, connected deployment with at least one executable action,
  # the same compatible set dispatch reads. Deduped (two trusted versions of one
  # pack collapse to one id) and sorted so the response is deterministic.
  defp dispatchable_pack_ids(runner, packs) do
    packs
    |> Enum.filter(fn pack ->
      case Map.get(pack.compatibility, runner.id) do
        nil -> false
        compatibility -> compatibility.compatible_action_ids != []
      end
    end)
    |> Enum.map(& &1.pack_id)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # `matched` is the total; the four status keys are a breakdown of it. The
  # schema is `additionalProperties: false` with exactly those five required
  # keys and it freezes at 1.0, so a fifth runner status cannot be added here —
  # and compatibility.md already names `runner_revoked` as a distinct terminal
  # state. This used to be `Map.update!`, which RAISES on a key that is not in
  # the map: the day a fifth status exists, `list_runners` would stop answering
  # at all for every account that had one. A status outside the breakdown is
  # now simply absent from it, still counted in `matched`, so the tool keeps
  # working and the total stays honest.
  #
  # Which means a client must not assume the four sum to `matched`. The schema
  # says so; adding that description was additive.
  @summary_statuses ~w(connected disconnected pending disabled)

  defp runner_summary(runners) do
    counted =
      Enum.reduce(runners, %{}, fn runner, acc ->
        if runner.status in @summary_statuses,
          do: Map.update(acc, runner.status, 1, &(&1 + 1)),
          else: acc
      end)

    Map.new(
      [{"matched", length(runners)} | Enum.map(@summary_statuses, &{&1, counted[&1] || 0})],
      fn {key, value} -> {String.to_existing_atom(key), value} end
    )
  end

  # "all" keeps everything; otherwise the mode names the exact state to keep.
  defp include_deployment?("all", _availability), do: true
  defp include_deployment?(mode, availability), do: mode == availability

  defp paginate_candidates(candidates, scope, args) do
    # A keyset cursor can only advance through a list that ascends in its key,
    # and `cover_query_concepts/1` deliberately breaks score order by promoting
    # concept champions to the head. Paging on a score-derived key therefore
    # resumed at the first promoted row instead of after the last emitted one —
    # repeating rows, and returning page 1 verbatim whenever that row was the
    # head, which is an unbounded loop for a client told to follow `next`
    # verbatim. Page on the FINAL rank, which ascends by construction whatever
    # the ranking did; action_id + pack_ref keep the key naming one exact row.
    # The width is derived from the count so the padding can never overflow.
    width = candidates |> length() |> Integer.to_string() |> byte_size()

    paginate(
      "find_actions",
      candidates,
      &search_key(&1, width),
      scope,
      args,
      :candidates,
      &candidate_result/1
    )
  end

  # An exact action_id filter names ONE action, so an empty result is a claim
  # about that action rather than a search that found nothing.
  defp exact_action_filter?(%{action_id: action_id}) when is_binary(action_id), do: true
  defp exact_action_filter?(_args), do: false

  # The pack that ships this action, matched the way searchable_actions/3 does
  # but WITHOUT the runner-availability filter — "we ship this and it is trusted;
  # nothing in scope can run it". nil means the action genuinely is not in the
  # catalog, which is an ordinary empty search result. Sorted so a hand-off names
  # the same pack every time when an id appears in more than one.
  defp deployed_pack_ref(snapshot, args) do
    snapshot.packs
    |> Enum.filter(fn pack ->
      (is_nil(args.pack_id) or pack.pack_id == args.pack_id) and
        (is_nil(args.pack_ref) or pack.pack_ref == args.pack_ref) and
        Enum.any?(pack.actions, &(&1["action_id"] == args.action_id))
    end)
    |> Enum.map(& &1.pack_ref)
    |> Enum.sort()
    |> List.first()
  end

  # The same answer get_action already gives for the same condition. The
  # continuation carries pack_ref as well as action_id because list_runners
  # REQUIRES the pack once an action is named — an action id alone is ambiguous
  # across packs, and find_actions can be filtered by action_id on its own.
  defp unavailable_action_error(args, pack_ref) do
    payload =
      error(
        "action_unavailable",
        "No in-scope connected runner can execute this exact trusted action."
      )

    next = %{
      tool: "list_runners",
      arguments: %{action_id: args.action_id, pack_ref: pack_ref, limit: 15}
    }

    {:error, put_in(payload, [:error, :next], next)}
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

  # Operator queries arrive as questions ("is autovacuum keeping up?"), so raw
  # substring token matching let filler words ("is" inside "redis", "up" inside
  # "group") outscore the real target, and plurals missed containment entirely.
  # Tokens therefore drop stop words, match on word prefixes in either
  # direction (inode/inodes), and weigh by rarity across the searchable set —
  # a token appearing in one action outweighs one appearing in forty.
  @stop_words ~w(a an and are be can do does for how i in is it its keep keeping
                 my of on or our that the this to was we what when which why with
                 you your)

  # Generic ops abbreviation/equivalence families only — a query token matches
  # through any member of its group. Symptom vocabulary ("sluggish", "under
  # attack") deliberately does NOT live here: it belongs in each action's
  # reviewed `search_terms`, where a human vouches that the action answers it.
  @synonym_groups [
    ~w(db database databases),
    ~w(mem memory ram),
    ~w(fs filesystem filesystems),
    ~w(net network networking),
    ~w(cert certificate certificates tls ssl),
    ~w(config configuration conf),
    ~w(conn connection connections),
    ~w(repl replication replica replicas),
    ~w(proc process processes pid),
    ~w(auth authentication login logins),
    ~w(perf performance),
    ~w(dir directory directories folder),
    ~w(restart reboot),
    ~w(container containers docker),
    ~w(k8s kubernetes)
  ]
  @synonyms Map.new(
              Enum.flat_map(@synonym_groups, fn group ->
                Enum.map(group, &{&1, group})
              end)
            )

  defp score_candidate(candidate, %{action_id: action_id}, _weights)
       when is_binary(action_id) do
    if candidate.action["action_id"] == action_id,
      do: Map.merge(candidate, %{score: 10_000, matched_fields: ["action_id"], token_claims: %{}})
  end

  defp score_candidate(candidate, %{query: nil}, _weights),
    do: Map.merge(candidate, %{score: 1, matched_fields: [], token_claims: %{}})

  defp score_candidate(candidate, %{query: query}, weights) do
    query = query |> String.downcase() |> String.trim()
    action = candidate.action
    id = String.downcase(action["action_id"])
    title = String.downcase(action["title"])
    terms = Enum.map(action["search_terms"], &String.downcase/1)
    tokens = Map.keys(weights)

    {term_score, term_fields, term_claims} =
      score_query_terms(tokens, weights, candidate.search_words)

    {score, fields, token_claims} =
      cond do
        id == query ->
          {10_000, ["action_id"], term_claims}

        String.starts_with?(id, query) ->
          {8_000, ["action_id"], term_claims}

        title == query ->
          {7_000, ["title"], term_claims}

        query in terms ->
          {6_000, ["search_terms"], term_claims}

        term_score > 0 ->
          {term_score, term_fields, term_claims}

        String.jaro_distance(query, id) >= 0.88 ->
          {2_000, ["action_id"], %{}}

        String.jaro_distance(query, title) >= 0.9 ->
          {1_000, ["title"], %{}}

        true ->
          {0, [], %{}}
      end

    if score > 0 do
      Map.merge(candidate, %{score: score, matched_fields: fields, token_claims: token_claims})
    end
  end

  defp score_query_terms(tokens, weights, search_words) do
    matched =
      tokens
      |> Enum.map(fn token -> {token, matching_fields(token, search_words)} end)
      |> Enum.reject(fn {_token, fields} -> fields == [] end)

    if matched == [] do
      {0, [], %{}}
    else
      rarity = matched |> Enum.map(fn {token, _fields} -> weights[token] end) |> Enum.sum()

      score =
        min(
          @max_search_score,
          3_000 + rarity +
            Enum.count(matched, fn {_token, fields} -> "action_id" in fields end) * 300 +
            Enum.count(matched, fn {_token, fields} -> "title" in fields end) * 200 +
            Enum.count(matched, fn {_token, fields} ->
              "summary" in fields or "search_terms" in fields
            end) * 100
        )

      fields = matched |> Enum.flat_map(&elem(&1, 1)) |> Enum.uniq()
      {score, fields, token_claims(matched, weights)}
    end
  end

  # A candidate's CLAIM on a query token, for concept-coverage promotion: full
  # rarity when the token matches the action's own identity or its reviewed
  # operator vocabulary, half when it only appears in passing summary prose.
  # The disk-usage action names disk usage in its id and title; an action whose
  # summary merely mentions parsed disk output is describing itself, not
  # answering that concept — the field is the evidence quality.
  defp token_claims(matched, weights) do
    Map.new(matched, fn {token, fields} ->
      weight = weights[token]

      if Enum.any?(fields, &(&1 in ["action_id", "title", "search_terms"])) do
        {token, weight}
      else
        {token, div(weight, 2)}
      end
    end)
  end

  # An operator's client often sends the WHOLE task as one query — "uptime,
  # disk usage, and a redacted JSON demo" — and under pure score order the
  # actions matching the most tokens crowd out the best answer for each
  # individual concept. The client reads only the top of the list, so the
  # first slots go to concept champions: each pick is the remaining candidate
  # with the largest yet-unanswered token claim, score breaking ties. Claims
  # are field-aware (see token_claims/2), so the action NAMED for a concept
  # outbids one whose prose mentions it in passing, and a stray rare word in a
  # summary cannot buy a slot from the concept's real answer. Promotion stops
  # the moment nothing uncovered remains claimed — from there the list is
  # already in score order. Focused single-concept queries are unaffected:
  # their top result covers their whole query on the first pick.
  defp cover_query_concepts(candidates) do
    cover_query_concepts(candidates, MapSet.new(), [])
  end

  defp cover_query_concepts([], _covered, picked), do: Enum.reverse(picked)

  defp cover_query_concepts(candidates, covered, picked) do
    {candidate, unanswered_claim} =
      candidates
      |> Enum.map(fn candidate -> {candidate, unanswered_claim(candidate, covered)} end)
      |> Enum.max_by(fn {candidate, claim} -> {claim, candidate.score} end)

    if unanswered_claim == 0 do
      Enum.reverse(picked, candidates)
    else
      covered = candidate.token_claims |> Map.keys() |> Enum.into(covered)
      candidates = List.delete(candidates, candidate)
      cover_query_concepts(candidates, covered, [candidate | picked])
    end
  end

  defp unanswered_claim(candidate, covered) do
    candidate.token_claims
    |> Enum.reject(fn {token, _claim} -> MapSet.member?(covered, token) end)
    |> Enum.map(fn {_token, claim} -> claim end)
    |> Enum.sum()
  end

  defp matching_fields(token, search_words) do
    variants = token_variants(token)

    search_words
    |> Enum.filter(fn {_field, words} -> variants_match?(words, variants) end)
    |> Enum.map(&elem(&1, 0))
  end

  defp token_variants(token), do: Map.get(@synonyms, token, [token])

  defp variants_match?(words, variants) do
    Enum.any?(variants, fn variant -> Enum.any?(words, &word_match?(&1, variant)) end)
  end

  defp candidate_matches?(candidate, variants) do
    Enum.any?(candidate.search_words, fn {_field, words} -> variants_match?(words, variants) end)
  end

  # Prefix in either direction covers plural and inflected forms
  # (inode/inodes, sync/synchronization); the reverse direction requires a
  # substantial word so a short token cannot re-open the substring floodgate.
  defp word_match?(word, token) do
    String.starts_with?(word, token) or
      (byte_size(word) >= 4 and String.starts_with?(token, word)) or
      shared_stem?(word, token)
  end

  # "redacted" must find "redaction": inflection pairs often share a stem but
  # diverge at the suffix, so neither is a prefix of the other and both prefix
  # directions miss. Two words agreeing on their first six letters count as one
  # concept (redact-ed/-ion, replicat-ed/-ion) — six is the shortest agreement
  # that keeps unrelated pairs like content/context apart. Words are [a-z0-9]+
  # by construction, so byte slicing is character slicing.
  defp shared_stem?(word, token) do
    byte_size(word) >= 6 and byte_size(token) >= 6 and
      binary_part(word, 0, 6) == binary_part(token, 0, 6)
  end

  defp put_search_words(candidate) do
    action = candidate.action

    search_words = [
      {"action_id", field_words(action["action_id"])},
      {"title", field_words(action["title"])},
      {"summary", field_words(action["summary"])},
      {"search_terms", Enum.flat_map(action["search_terms"], &field_words/1)}
    ]

    Map.put(candidate, :search_words, search_words)
  end

  defp field_words(nil), do: []

  defp field_words(text) do
    text |> String.downcase() |> String.split(~r/[^a-z0-9]+/, trim: true)
  end

  # Rarity weight per salient query token: a token matching one action scores
  # ~1,000, one matching every action scores 0. Stop words are dropped unless
  # the whole query is stop words.
  defp token_weights(%{query: query}, searchable) when is_binary(query) do
    tokens =
      query
      |> String.downcase()
      |> String.split(~r/[^a-z0-9]+/, trim: true)
      |> Enum.uniq()

    salient = Enum.reject(tokens, &(&1 in @stop_words))
    tokens = if salient == [], do: tokens, else: salient
    total = max(length(searchable), 2)

    Map.new(tokens, fn token ->
      variants = token_variants(token)
      hits = Enum.count(searchable, &candidate_matches?(&1, variants))

      weight =
        if hits == 0 do
          0
        else
          round(1_000 * :math.log(total / hits) / :math.log(total))
        end

      {token, weight}
    end)
  end

  defp token_weights(_args, _searchable), do: %{}

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
    runners
    |> Enum.filter(fn runner ->
      runner.id in action.compatible_runner_ids and
        (args.runner_refs == [] or runner.runner_ref in args.runner_refs) and
        (is_nil(args.target) or runner_query_match?(runner, args.target))
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
        {:error, error("invalid_cursor", Service.invalid_cursor_message(:page, tool))}
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

  defp search_key(candidate, width) do
    rank = candidate.rank |> Integer.to_string() |> String.pad_leading(width, "0")
    rank <> "\0" <> candidate.action["action_id"] <> "\0" <> candidate.pack_ref
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
      include: args["include"] || "executable",
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
