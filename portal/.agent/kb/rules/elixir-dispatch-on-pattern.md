# Rule: dispatch on a pattern, not an inner `if`

**Rule.** A closure or function whose body is a single `if`/`case` testing a
*pattern-matchable* property of its argument (a field's nil-ness / truthiness, a
literal value, a struct shape) becomes function clause heads instead.

**Why.** Clause heads document the cases in the signature and let the reader see
the dispatch at a glance; an inner `if` buries it in the body. Keep `if` for
genuinely *computed* conditions (comparisons, function-call results) and `case`
for matching something *other than* the argument itself (e.g. `conn.assigns[:x]`).

**✅ Good**

```elixir
defp link_paddle_customer_if_unlinked(%Account{paddle_customer_id: nil} = account, id),
  do: Account.Changeset.link_paddle_customer(account, id)

defp link_paddle_customer_if_unlinked(%Account{} = account, _id),
  do: Ecto.Changeset.change(account)
```

**❌ Bad**

```elixir
fn account, id ->
  if account.paddle_customer_id == nil do
    Account.Changeset.link_paddle_customer(account, id)
  else
    Ecto.Changeset.change(account)
  end
end
```

**Enforced.** Partly. Credo (`Emisar.Checks.NoIfOnArgField`) flags only the
narrowest decidable form: a single-clause, single-argument `fn` whose body is an
`if` on the bare truthiness of that argument's field (`fn x -> if x.field …`).
Everything else stays judgment for review, `/elixir-iron-review`, and the
per-function audit — equality comparisons such as `== nil`, closures with more
than one argument (the ❌ example above is one), named functions, and `case`
on the argument. Whether such a condition is pattern-matchable (safe to convert)
or genuinely computed is not a call the check makes.
