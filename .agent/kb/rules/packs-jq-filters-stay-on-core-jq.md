# Rule: pack jq filters stay on core jq

**Rule.** A pack's jq program — in a packaged `scripts/*.sh` or an action's
`/bin/sh -c` argv — uses only builtins every jq build has. The regex family
(`test`, `match`, `capture`, `scan`, `splits`, `split/2`, `sub`, `gsub`) is
**optional**: it exists only when jq was linked against Oniguruma. Spell those
jobs with core jq — `explode`/`implode` for character classes, `split/1` +
`all` for shape checks, `ascii_downcase` + `contains`/`startswith`/`endswith`
for case-insensitive matching, `ltrimstr`/`rtrimstr` for fixed affixes.

**Why.** jq's own `./configure --with-oniguruma=no` is a supported build, and
minimal images and appliance hosts use it. Such a jq does not fall back and does
not degrade — it raises

```
jq: error (at <unknown>): jq was compiled without ONIGURUMA regex library.
match/test/sub and related functions are not available.
```

the moment a filter reaches one of those functions, and exits 5. In a pack that
means the action fails on that host and nowhere else: the same action, same
version, same trusted hash works on every developer box and every CI runner.
`requires.binaries: [jq]` cannot express "a jq with regex", so nothing warns the
operator; they just see an action that never works on one part of the fleet.

Worse, the failure lands *after* the command has run. The projection is the last
step of a read: HCP Terraform has been queried, the log has been fetched, and
then jq refuses — so the operator pays for the call and gets an error whose text
is about jq's build flags.

**Good.** Collapse control runs to one space (Oniguruma's `[[:cntrl:]]` is
exactly Unicode Cc — `U+0000`–`U+001F` and `U+007F`–`U+009F`, which is a closed
set, so it spells out exactly):

```jq
def controls_collapsed:
  (explode | map(if . <= 31 or (. >= 127 and . <= 159) then 0 else . end)) as $cs
  | [range($cs | length) | select(. == 0 or $cs[.] != 0 or $cs[. - 1] != 0) | $cs[.]]
  | map(if . == 0 then 32 else . end)
  | implode;
```

Every control codepoint becomes `0` — itself a control, so no ordinary character
collides with the marker — each run keeps only its first, and the survivor
becomes a space. A space already in the text is left alone, which is what
`gsub("[[:cntrl:]]+"; " ")` did.

A `0.x`/`1.x` shape check:

```jq
def all_digits: length > 0 and (explode | all(.[]; . >= 48 and . <= 57));

def plan_format_supported($version):
  ($version | type) == "string"
  and (($version | split(".")) as $parts
       | ($parts | length) == 2
       and ($parts[0] == "0" or $parts[0] == "1")
       and ($parts[1] | all_digits));
```

Case-insensitive matching against a known word:

```jq
select(((.Type // "") | ascii_downcase) | contains("restart"))
```

**Bad.**

```jq
(tostring | gsub("[[:cntrl:]]+"; " ")) as $clean          # optional builtin
if (.format_version | test("^[01]\\.[0-9]+$")) then . end  # optional builtin
select((.Type // "") | test("Restart"; "i"))               # optional builtin
```

**A rewrite is not automatically equivalent — prove it.** Two traps found while
doing this:

- Oniguruma's `$` matches before a trailing newline, so
  `test("^[01]\\.[0-9]+$")` accepted `"1.0\n"`. The core-jq version refuses it.
  Stricter is the right direction for a fail-closed gate, but decide it
  deliberately rather than discovering it in production.
- `[[:cntrl:]]` under jq's UTF-8 Oniguruma matches Cc **only** — not Cf, `Zl`,
  or `Zp`. A rewrite that also strips `U+2028`/bidi marks changes what the
  byte-budget arithmetic in a bounded projection was calibrated against.

Run both spellings over one corpus — every control codepoint alone, doubled, in
runs, beside a real space, at the clip boundaries in codepoints *and* UTF-8
bytes, plus the non-string inputs the helper coerces — and diff the output. That
differential is what made this change safe to ship; jq's regex build is what
made it necessary.

**How it's enforced.** An authoring-time lint, plus behavior cases over the
branches it cannot execute.

`./run pack check <name>` and `./run gate packs` run `validatePackJQFilters`
(`tools/internal/devtool/pack_jq.go`), which reads every jq program a pack can
actually execute — an action's `/bin/sh -c` argv and each packaged
`scripts/*.sh` — and fails on a call to the regex family or `split/2`, naming
the action and the builtin. It skips comments in both languages, strings (so a
`"x5t#S256"` key stays a key), and the `awk`/`sed`/`perl` spans that have their
own `match`/`sub`/`gsub`. That is what closes every executable path in the
catalog, which a case cannot: the failure is raised when the builtin is
*reached*, so a case only ever proves the paths it runs.

The cases prove the other half — that the core-jq rewrite still answers the way
the regex spelling did on the host where the regex spelling never ran.
`dev/test-packs/Dockerfile` builds jq `--with-oniguruma=no --disable-shared`
into the shared client image at `/opt/jq-without-regex/jq`, and a case opts in
by putting that directory first on `PATH`:

```yaml
    env:
      PATH: /opt/jq-without-regex:/opt/emisar/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

Every other case keeps running against the packaged Oniguruma-enabled jq, which
is what an operator's host usually has. `--disable-shared` is load-bearing: a
libtool build leaves `jq` linked against the libjq it just built, and that binary
copied into the final image silently resolves Debian's libjq — Oniguruma and all
— so the image asserts its own claim (`! jq -n '"a" | test("a")'`) after the
`COPY`.

`terraform-readonly`, `hcp-terraform`, `docker`, `oidc-jwks`, `firewall`,
`nomad`, and `bunnycdn` each carry one over the branch that used to call a
regex builtin: a control-collapsing clip, a plan-format gate, a numeric-string
port operand, a case-insensitive event match, a credential strip.

**Sweep.**
`rg -n 'gsub|\btest\(|\bmatch\(|capture\(|scan\(|splits\(|\bsub\(' packs/*/scripts/*.sh packs/*/actions/*.yaml`,
then read each hit: jq, or the `awk`/`sed` in the same pipeline (both have their
own `match`/`sub`/`gsub` and are unaffected). The lint is the mechanical version
of this grep and runs in the gate, so the grep is for the places it does not
reach — a test fixture, a repository tool, a document. As of 2026-08-04 every
pack in the catalog is on core jq.
