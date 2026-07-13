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
defp link_customer(%Account{paddle_customer_id: nil} = account, id),
  do: Accounts.link_paddle_customer(account, id)

defp link_customer(%Account{} = account, _id), do: {:ok, account}
```

**❌ Bad**

```elixir
fn account, id ->
  if account.paddle_customer_id == nil do
    Accounts.link_paddle_customer(account, id)
  else
    {:ok, account}
  end
end
```

**Enforced.** Judgment — review and `/iron-review`. Whether a condition is
pattern-matchable (safe to convert) vs. genuinely computed is a call a regex
can't make, so this is not a Credo check; it's caught in review and the
per-function audit. The taste-pipeline endpoint for a judgment rule is the
worked example here, not an automated check.
