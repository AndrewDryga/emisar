# Rule: a path argument needs real containment, not an anchored pattern

**Rule.** A path argument that a command actually *reads or writes* MUST
declare a nonempty `allowed_prefixes` (subpaths under a directory) or
`allowed_paths` (a fixed set of whole paths) in the same `validation:` block.
`denied_prefixes`/`denied_paths` are optional *additional* exclusions carved
out of that allowlist — they are not containment and never substitute for one.
An anchored `pattern` alone is **not** path containment either, however tight
it looks.

**Why.** Two different things are easy to confuse here, and only one of them
confines the argument.

*Canonical resolution* is activated by **any** of the four path fields —
`allowed_prefixes`, `allowed_paths`, `denied_prefixes`, `denied_paths`
(`hasPathValidation`, `runner/pkg/actionspec/args.go`), which is also the early
return in `applyPathValidation` (`runner/internal/validation/args.go`). That
pass is what runs `Clean` + `EvalSymlinks` over the value, collapses `..`,
blocks a symlink escape, and requires an absolute path. It never runs off
`pattern`.

*Confinement* is a separate, positive test inside that same function, and only
an allowlist performs it:

```go
if len(allowedPaths) > 0 && !pathInList(resolved, allowedPaths) { … }
if len(allowedPrefixes) > 0 && !prefixInList(resolved, allowedPrefixes) { … }
```

With both allowlists empty there is no positive test at all: a deny-only rule
rejects the locations it names and **accepts every other resolvable absolute
path**. Getting canonical resolution is not the same as being contained.

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

Naming the secrets you thought of does not fix it either — a denylist is a
list of the attacks you already imagined:

```yaml
# ❌ resolves canonically, contains nothing
- name: log_file
  validation:
    pattern: "^/var/log/nginx/[A-Za-z0-9._/-]{1,128}$"
    denied_paths: ["/etc/shadow"]
    denied_prefixes: ["/etc/ssh/"]
```

`/etc/shadow` is refused; `/home/deploy/.pgpass` is handed straight to the
command. Add the allowlist and the same argument is confined, with the deny
rules still carving their exclusions out of it:

```yaml
# ✅ contained
- name: log_file
  validation:
    pattern: "^/var/log/nginx/[A-Za-z0-9._/-]{1,128}$"
    allowed_prefixes: ["/var/log/nginx/"]
    denied_paths: ["/var/log/nginx/private.log"]   # optional extra exclusion
```

Use `allowed_prefixes` for "any file under this directory". `allowed_paths` is
exact-match and rejects real files under the dir, so it is the wrong field for
a subpath argument (it is right for a fixed set of whole paths). Either one
satisfies the rule; a deny field alone does not.

`TestValidate_DenyOnlyAdmitsEveryUnlistedPath`
(`runner/internal/validation/args_test.go`) pins all three behaviors against
the real validator, entirely under `t.TempDir()`: the deny-only rule refuses
the path it names, admits the intended in-directory read, and **also admits an
unlisted path in another directory** — and adding `allowed_prefixes` keeps the
in-directory read passing while turning that third value into an
`allowed_prefixes` rejection.

**The one exception.** A pack whose *job* is arbitrary filesystem access —
`fs-search`, `ssl-local`, `nomad.alloc_fs_tail` — has no directory to allowlist
without hardcoding a fleet, which [[packs-target-args-gate-on-risk-tier]]
forbids. There the deny lists are a partial exclusion and the **risk tier is
the whole gate**: tier the action for what it can **emit** from the worst file
it can read. `fs.head_file`/`fs.grep_file` are `medium` because they echo the
file's bytes; `fs.stat_path`/`fs.ls_long` are `low` on metadata — and so are
`fs.sha256_file`/`fs.count_lines`/`fs.file_type`, which read the whole of an
arbitrary file and stay `low` because they return a derivation rather than the
content. Read-vs-metadata is the wrong cut and mis-tiers that middle group;
[[packs-risk-tiers-follow-real-life-impact]] carries the emit-based line and
ssl-local's worked decision. Taking that exception is a deliberate design
statement about the action's purpose, not a shortcut for an argument that was
meant to stay in one directory.

**Sweep signal.** Any path argument a command dereferences whose
`validation:` block has no nonempty `allowed_prefixes` or `allowed_paths`, and
whose action is not deliberately a whole-filesystem tool — whether it is
bounded by a `pattern: "^/…"` alone or by `denied_prefixes`/`denied_paths`
alone. A deny-only block is the harder one to spot, because it looks like path
validation and does resolve canonically.

**How it's enforced.** Review, not tooling — the loader cannot tell which
argument a command dereferences as a path from the argv template alone, and
nothing in `Arg.Validate` requires an allowlist beside a deny list. The
bound-every-argument requirement it does enforce is satisfied by the `pattern`
or by a deny field, which is exactly why this class passes validation and still
escapes. Tier the action for what the contained directory can expose:
[[packs-risk-tiers-follow-real-life-impact]], and bound its size per
[[packs-arg-bounds-follow-backend-limits]].
