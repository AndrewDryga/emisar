# Rule: no pipe in a `with` / `case` / `for` head

**Rule.** Never put a pipe (`|>`) in the expression being matched in a `with`,
`case`, or `for` clause head — not even on one line. Bind the pipeline to a name
first, then match the short call.

**Why.** `{:ok, x} <- a() |> b() |> c()` hides *which* operation is being matched
and what shape it returns. Binding the pipeline above the head makes the match
read flat and names the thing being matched.

**✅ Good**

```elixir
queryable = Token.Query.all() |> Token.Query.by_prefix(prefix)

with {:ok, token} <- Repo.peek(queryable) do
  {:ok, token}
end
```

**❌ Bad**

```elixir
with {:ok, token} <- Token.Query.all() |> Token.Query.by_prefix(prefix) |> Repo.peek() do
  {:ok, token}
end
```

**Enforced.** Credo — `Emisar.Checks.NoPipeInBranchHead` (matches the AST, so the
one-line, wrapped, and `case`-head forms are all caught). Runs on `mix credo` and
at the commit gate. A documented exception gets
`# credo:disable-for-next-line Emisar.Checks.NoPipeInBranchHead` under its
why-comment — never a bare disable.
