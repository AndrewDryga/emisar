# A pack never gets privileges from a setuid or setgid helper

**Rule.** The runner sets `no_new_privs` on every action child, so a setuid bit,
a setgid bit, or a file capability on the binary an action runs **does not
elevate** — at any depth, for the life of the process tree. An action that
reaches a resource only through such a helper works for a runner that already
has direct access and fails for one that does not. Author the action's
`requires`/notes to state the access the runner user needs, and give its
behavior case an identity that really has it (`runner_user: root` with a
`runner_reason`, or an `arrange` step that grants direct access).

**Why.** `no_new_privs` is what makes the runner's drop to an unprivileged user
a boundary at all: without it a dropped child can exec any setuid binary on the
host and climb straight back out of the credential it was confined to. Keeping
it means some ordinary-looking read actions need real access instead of
borrowing it from a helper — that is the trade, and it is the right one for a
binary that runs commands on production hosts.

The trap is that the helper hides the requirement. `mailq` looks like a plain
read; it works for any user on a normal host **because `postqueue` is setgid
`postdrop`**. Under `no_new_privs` it returns `Permission denied` and exit 69,
and a behavior case that never declared an identity is the only thing that
notices.

**✅ Good**

```yaml
# packs/postfix/test/cases.yaml
- action: postfix.mailq
  runner_user: root
  runner_reason: >-
    Postfix keeps the showq socket under a postdrop-group directory, and
    postqueue reaches it by being setgid postdrop. The runner sets no_new_privs
    on every action child, so that bit no longer elevates.
```

**❌ Bad**

```yaml
# Passes only because postqueue's setgid bit used to elevate. The pack's own
# note already said the runner user must own the queue or be in postdrop.
- action: postfix.mailq
  expect:
    stdout_contains: [Mail queue is empty]
```

**How it's enforced.** Review + the Linux behavior matrix, not a lint: which
binaries carry a setuid/setgid bit or file capabilities is distro-dependent, so
a static allowlist would fire on correct packs and miss real ones. The signal to
look for is an action whose binary is a classic privileged helper — `mailq`,
`postqueue`, `ping`, `mtr`, `traceroute`, `crontab`, `at`, `dmesg`, `mount` —
with a behavior case that declares no `runner_user`. A workstation cannot judge
this class either way; see
[`shared-ci-decides-what-a-workstation-cannot`](shared-ci-decides-what-a-workstation-cannot.md).
