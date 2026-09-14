# A byte budget is derived from byte bounds, and a size failure says "too large"

Two rules, because one bug needs both to stay fixed.

## Rule 1 — a budget measured in bytes is derived from bounds measured in bytes

`Ecto.Changeset.validate_length/3` counts **graphemes** by default
(`deps/ecto/lib/ecto/changeset.ex`: `count_type = opts[:count] || :graphemes`).
A grapheme carries no byte bound at all — one CJK character is 3 bytes, one
family emoji is 25, and a base letter followed by combining marks is a single
grapheme of as many bytes as the writer cares to append — so a character limit
tells you nothing about how much room a value needs on the wire. The same holds
for a display cut: `String.split_at/2` and `String.slice/3` count graphemes, so
a 2,000-"character" bound can pass 32 KiB of text through untouched and
unflagged.

When a payload has a size ceiling, **derive it from the byte ceilings its parts
actually enforce**, and give any free-text part a `count: :bytes` validation
beside its character one. Never pick a ceiling and assume headroom.

Measure the result anyway. JSON escaping expands a control character to six
bytes, so a derived budget is a guarantee about well-formed content, not about
hostile content — the measurement is what stays honest.

## Rule 2 — a size limit is reported as a size limit

A caller who hits a mechanical limit is told so. Do not fold it into a
security-shaped denial. Those exist for resource-resolution failures — an
untrusted pack, an out-of-scope runner — which must stay indistinguishable from
"does not exist" or they leak the existence of infrastructure outside the
caller's scope. Size is not that kind of fact and leaks nothing.

## Why

`RunbookContract.project/2` gated size inside the same `with` that validated the
definition, so both fell to `{:error, :incomplete_contract}` — a member of
`RunbookTools.@hidden_contract_reasons`. `list_runbooks` dropped the runbook
silently and `get_runbook` answered *"No published runbook has that exact ref"*
about a runbook open in the operator's own console.

It was reachable. The definition cap is 65,536 **bytes**; `title` (80) and
`description` (4,096) were **graphemes**, and the 72 KiB budget assumed 8 KiB of
headroom over the definition. Encoded at those limits: ASCII 70,254 (fit),
accented Latin 74,430 (over), Japanese 78,606 (over). Writing a description in
your own language was enough to make your runbook disappear.

## ✅ Good

```elixir
# The bound the budget spends is stated in the unit the budget spends.
|> validate_length(:description, max: 4_096)
|> validate_length(:description, max: @max_description_bytes, count: :bytes)
```

```elixir
# Derived, not guessed — and still measured.
@max_projection_bytes Runbooks.definition_limit!(:max_definition_bytes) +
                        Runbooks.metadata_limit!(:title_bytes) +
                        Runbooks.metadata_limit!(:description_bytes) + @max_envelope_bytes

defp fit(projection) do
  size = encoded_size(projection)
  if size <= @max_projection_bytes, do: :ok, else: {:too_large, size}
end
```

```elixir
# Size is named; only resolution failures stay hidden.
{:error, {:runbook_too_large, bytes}} -> {:error, runbook_too_large(bytes)}
{:error, reason} when reason in [:not_found, :incomplete_contract] -> {:error, not_found(status)}
```

## ❌ Bad

```elixir
# 4,096 of WHAT? Not of the bytes the budget is spending.
|> validate_length(:description, max: 4_096)

# A guessed ceiling with assumed headroom.
@max_projection_bytes 72 * 1_024

# Both failures leave by the same door, so a size limit answers "no such thing".
with {:ok, definition} <- validate(runbook.definition),
     projection <- build(definition),
     true <- encoded_size(projection) <= @max_projection_bytes do
  {:ok, projection}
else
  _invalid_or_oversized -> {:error, :incomplete_contract}
end
```

## Sweep

- `validate_length` with a `max:` on a free-text field (no `count:`) whose value
  reaches a size-bounded payload. Identifier-shaped fields — hashes, refs,
  slugs, prefixes, IPs — are ASCII by construction and need nothing.
- A `@max_*_bytes` module attribute written as a literal rather than derived
  from the bounds of the things it holds.
- A size comparison sharing an `else` (or a `with` fall-through) with a
  validation or resolution failure.
- A bound feeding a frame that carries the value as JSON: spend it in
  **encoded** bytes. `\` and `"` escape to two bytes, and a payload mirrored
  as a JSON text block escapes them again to four, so a ceiling in decoded
  bytes bounds the wire at three times the ASCII cost. The review receipt's
  justification chain and its command line both count `Jason.encode!/1` output
  for this reason, through the one `Emisar.EncodedText` so they cannot drift.
- A payload budgeted in bytes that is never MEASURED. Deriving the budget is
  not the same as checking it: `EmisarWeb.MCP.Service.fixed_run_tail/4` sized
  its continuations against the real assembled frame while `fixed_run_summary/3`
  set a raw-byte preview cap and shipped whatever that produced, so an
  escape-heavy snapshot answered at 99,546 bytes against a 65,536-byte budget.
- A slice bounding a value against a schema limit: match the unit the schema
  counts. JSON Schema `maxLength` counts **code points**, and `String.slice/3`
  counts graphemes — a combining cluster carries two code points per grapheme
  past a limit that looks obeyed.
- A ceiling on the NUMBER of items in a size-budgeted collection, with no
  ceiling on what each item costs. A count is not a size: the review receipt
  capped its vote history at 20 and each note at 2,000 graphemes, and twenty
  maximal CJK notes still encoded to 290,934 bytes against a 65,536-byte page.
  Bound the item AND give the collection a shared byte allowance, spent in the
  order the collection already prefers, so what it drops is reported by the
  count it already publishes.
- A truncation flag that only ONE consumer renders. A bound added for a
  size-budgeted frame usually lives in a projection an unbudgeted surface reads
  too — the review receipt feeds both the MCP page and the console run page —
  and there the cut still happens while the budget that justified it does not
  apply. Every surface that prints the bounded value prints the flag beside it:
  `EncodedText.bound/2` returns a bare prefix, so a console quoting it without
  the flag publishes a clipped approver's note as the whole one.

Swept 2026-08-08: the runbook projection was the only collapsing size gate.
`ResponseBudget.encode_frame/1` (`:response_too_large`), the draft envelope
("Draft exceeds the encoded byte limit"), and the catalog page shrink all
already reported size as size.

## How it's enforced

Tests, not a Credo check: whether a bound feeds a byte budget needs the call
graph, and a check firing on every `validate_length` would train people to
disable it. `runbook_contract_test.exs` pins the guard firing with its byte
count, the envelope allowance covering the worst-case wrapper, and the code
point slice; `runbook/changeset_test.exs` pins CJK and emoji metadata that pass
the character limit and fail the byte one. `mcp_runbook_recovery_tools_test.exs`
pins the MCP review receipt: a combining-cluster command line, an emoji and a
backslash executed receipt, an escape-heavy snapshot preview, and a fully voted
receipt whose twenty maximal CJK notes ride a maximal justification chain and
command line each go through the real tool and are held to
`ResponseBudget.fits_model_page?/1`. `approvals_test.exs` pins the vote list's
shared allowance separately: what it drops is counted in `decisions_omitted`,
the votes it keeps are the newest and contiguous, and the stored audit receipt
still holds every byte of the note. `run_detail_live_test.exs` pins the console
side of that same projection: a note past the bound renders its cut instead of
quoting the clipped text as whole.
