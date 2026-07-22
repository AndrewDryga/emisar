# Rule: `@doc`/`@moduledoc` state the contract, never narrate the body

**Rule.** A doc states what a reader can't get faster from the signature — the
*contract* and the *why* — never a restatement of the code. A public function's
`@doc` gives: one line on what it does, the **`%Subject{}`/permission** it requires,
and the **return-shape tuple**, matching the real code. A context module's
`@moduledoc` is one paragraph naming it the public/authorization boundary for its
domain; a Query/Changeset/Schema gets one line (their role is already fixed by the
conventions). §1.4 internal helpers get `@doc "Internal — <who calls it>"`; a truly
private/uninteresting function gets `@doc false` or nothing. Document **as you
write** the function (`/elixir-context-fn`, `/elixir-new-context`), not in a later pass.

**Why.** The contract — which permission gates it, what shape it returns — is the
one thing the next caller can't read off the head, and the thing a `with` pipeline
breaks on if it's wrong. A doc that paraphrases the body line by line is noise that
rots the moment the body changes; a doc that says nothing is worse than none.

**✅ Good**

```elixir
@doc """
Archives a runbook. Requires `manage` on runbooks; scoped to the subject's account.

Returns `{:ok, runbook}` or `{:error, :not_found | :unauthorized}`.
"""
def archive_runbook(id, %Subject{} = subject)
```

**❌ Bad**

```elixir
@doc """
Takes an id and a subject, fetches the runbook by id, sets its deleted_at to now,
updates the row, and returns it.
"""
def archive_runbook(id, %Subject{} = subject)
```

(Narrates the body, omits the permission and the error shape, and goes stale the
moment the implementation changes.)

**Enforced.** Judgment — review and `/elixir-iron-review`. `mix compile
--warnings-as-errors` (IL-20) catches a `@doc` attached to a private or undefined
function; the rest — is it a contract or narration, is the stated permission /
return shape actually true — is a read a static check can't make, so it's caught in
review and the per-function audit, and applied at the point of writing by
`/elixir-context-fn` and `/elixir-new-context`. No "new/refactored version" notes (IL-11); no
examples that aren't real/tested.
