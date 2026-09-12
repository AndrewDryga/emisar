# Rule: a path argument needs real containment, not an anchored pattern

**Rule.** A path argument that a command actually *reads or writes* MUST
declare `allowed_prefixes` (subpaths under a directory), or
`denied_paths`/`allowed_paths`, in the same `validation:` block. An anchored
`pattern` alone is **not** path containment, however tight it looks.

**Why.** Only a path list activates the runner's containment. The `Clean` +
`EvalSymlinks` pass in `applyPathValidation`
(`runner/internal/validation/args.go`) is what collapses `..` and blocks a
symlink escape, and it runs only when the argument carries at least one of
`allowed_prefixes`, `allowed_paths`, `denied_prefixes`, or `denied_paths`
(`hasPathValidation`, `runner/pkg/actionspec/args.go`) — never off `pattern`.
A `pattern` constrains the lexical shape of the string and nothing more:

```yaml
# ❌ looks tight, contains nothing
- name: log_file
  validation:
    pattern: "^/var/log/nginx/[A-Za-z0-9._/-]{1,128}$"
```

`.` and `/` are literal members of that character class, so the pattern still
matches `/var/log/nginx/../../../etc/shadow`. Without a path list, a `low`,
no-approval read walks out of its directory to any root-readable secret —
`/etc/shadow`, a `.pgpass`, an arbitrary `.env`. Redaction does not save it:
redaction is pattern-bound and will not match most of that content.

```yaml
# ✅ contained
- name: log_file
  validation:
    pattern: "^/var/log/nginx/[A-Za-z0-9._/-]{1,128}$"
    allowed_prefixes: ["/var/log/nginx/"]
```

Use `allowed_prefixes` for "any file under this directory". `allowed_paths` is
exact-match and rejects real files under the dir, so it is the wrong field for
a subpath argument (it is right for a fixed set of whole paths).

**Sweep signal.** Any `pattern: "^/…"` on a path argument with no sibling
`allowed_prefixes`, `allowed_paths`, `denied_prefixes`, or `denied_paths` in
the same `validation:` block.

**How it's enforced.** Review, not tooling — the loader cannot tell which
argument a command dereferences as a path from the argv template alone. The
bound-every-argument requirement it does enforce is satisfied by the `pattern`,
which is exactly why this class passes validation and still escapes. Tier the
action for what the contained directory can expose:
[[packs-risk-tiers-follow-real-life-impact]], and bound its size per
[[packs-arg-bounds-follow-backend-limits]].
