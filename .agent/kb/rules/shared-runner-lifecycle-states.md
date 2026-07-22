# shared: reversible and terminal runner states stay distinct

**Rule.** Carry runner lifecycle semantics unchanged through context events,
transport reasons, HTTP responses, client retry policy, logs, and operator copy.
`disabled` is reversible and retains a retryable identity. `deleted` or `revoked`
is terminal and must not retry the invalid identity.

**Why.** Collapsing disable into revoke strands a valid runner until someone
restarts it on the host. Collapsing revoke into disable is worse: a removed or
compromised identity keeps retrying when the operator intended a permanent kill
switch.

Good: disable emits `runner_disabled`, rejects reconnects as a distinct temporary
state without deleting the cached token, and reconnects after enable. Delete emits
`runner_revoked`, invalidates the credential, and stops the runner.

Bad: one `runner_revoked` event or "disabled or removed" branch handles both
states, leaving the client unable to choose a correct retry policy.

**Sweep target.** Search portal, runner, protocol docs, doctor output, and tests
for shared disable/delete callbacks, `runner_revoked`, `runner_disabled`, and copy
that joins the states with "or". Verify every branch is explicitly reversible or
terminal.

**How it is enforced.** Portal contract tests pin distinct PubSub events and HTTP
responses. Runner transport tests pin shutdown classification, disabled-token
retention, retry behavior, and terminal revocation.
