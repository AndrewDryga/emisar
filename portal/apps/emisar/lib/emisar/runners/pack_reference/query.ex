defmodule Emisar.Runners.PackReference.Query do
  @moduledoc false
  use Emisar, :query

  def advertised_refs(_runners, []) do
    candidates([], [], [])
    |> select([pack_refs: c], {c.pack_id, c.version})
  end

  def advertised_refs(runners, refs) do
    {pack_ids, versions} = Enum.unzip(refs)

    runners
    |> matched_candidates(
      candidates(pack_ids, versions, List.duplicate("", length(refs))),
      :advertised
    )
    |> select([pack_refs: c], {c.pack_id, c.version})
  end

  def visible_deployments(_runners, []) do
    candidates([], [], [])
    |> select([pack_refs: c], {c.pack_id, c.version, c.hash})
  end

  def visible_deployments(runners, deployments) do
    {pack_ids, versions, hashes} =
      Enum.reduce(deployments, {[], [], []}, fn {pack_id, version, hash},
                                                {ids, versions, hashes} ->
        {[pack_id | ids], [version | versions], [hash | hashes]}
      end)

    runners
    |> matched_candidates(candidates(pack_ids, versions, hashes), :visible)
    |> select([pack_refs: c], {c.pack_id, c.version, c.hash})
  end

  defp candidates(pack_ids, versions, hashes) do
    from(
      c in fragment(
        "SELECT * FROM unnest(?::text[], ?::text[], ?::text[]) WITH ORDINALITY AS refs(pack_id, version, hash, ordinal)",
        ^pack_ids,
        ^versions,
        ^hashes
      ),
      as: :pack_refs
    )
  end

  defp matched_candidates(runners, candidates, mode) do
    candidates =
      select(candidates, [pack_refs: c], %{
        pack_id: c.pack_id,
        version: c.version,
        hash: c.hash,
        ordinal: c.ordinal
      })

    matches =
      pack_entries()
      |> join(:inner, [pack_entries: e], c in "retention_pack_candidates",
        as: :candidate_refs,
        on: e.key == c.pack_id
      )
      |> matching_values(mode)
      |> select([candidate_refs: c], c.ordinal)

    # Materialize computed ordinals, not TOAST pointers to runner pack maps.
    # Each consumed runner expands its JSON once; candidate EXISTS still stops
    # at its first witness. The DB may spill these <=100-element arrays, but
    # no fleet maps cross into the process and absent refs cannot re-detoast
    # every runner once per candidate. Both scans use the same already-scoped
    # runner query in one statement.
    evidence = select(runners, %{matching_ordinals: fragment("ARRAY(?)", subquery(matches))})

    present =
      from(e in "retention_pack_evidence",
        as: :pack_evidence,
        where: fragment("? = ANY(?)", parent_as(:pack_refs).ordinal, e.matching_ordinals),
        select: 1
      )

    from(c in "retention_pack_candidates", as: :pack_refs)
    |> with_cte("retention_pack_candidates", as: ^candidates, materialized: true)
    |> with_cte("retention_pack_evidence", as: ^evidence, materialized: true)
    |> where(exists(subquery(present)))
    |> order_by([pack_refs: c], asc: c.ordinal)
  end

  defp pack_entries do
    from(
      e in fragment(
        "jsonb_each(CASE WHEN jsonb_typeof(?) = 'object' THEN ? ELSE '{}'::jsonb END)",
        parent_as(:runners).packs,
        parent_as(:runners).packs
      ),
      as: :pack_entries,
      where: fragment("jsonb_typeof(?) = 'object'", e.value)
    )
  end

  defp matching_values(queryable, :advertised) do
    where(
      queryable,
      [pack_entries: e, candidate_refs: c],
      fragment(
        "COALESCE(NULLIF(NULLIF(? -> 'version', 'null'::jsonb), 'false'::jsonb), '\"unknown\"'::jsonb) = to_jsonb(?::text)",
        e.value,
        c.version
      )
    )
  end

  # Visibility requires exact JSON strings for version and effective hash;
  # retention's null/false/missing-version fallback does not apply here.
  defp matching_values(queryable, :visible) do
    where(
      queryable,
      [pack_entries: e, candidate_refs: c],
      fragment("? -> 'version' = to_jsonb(?::text)", e.value, c.version) and
        fragment("? -> 'hash' = to_jsonb(?::text)", e.value, c.hash)
    )
  end
end
