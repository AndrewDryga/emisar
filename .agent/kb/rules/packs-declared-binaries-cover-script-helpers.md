# Packs: declared binaries cover script helpers

## Rule

`requires.binaries` declares every host command an action actually runs, not
only the one the loader can see. Three places name a dependency:

1. `execution.command.binary` — the loader validates this one.
2. `execution.script.interpreter` — `bash` is declarable, `/bin/sh` is not.
3. The shell text itself — a packaged `scripts/*.sh` or an inline
   `/bin/sh -c '<program>'` that pipes through a helper such as `jq`.

The third is the one nothing else reads. A helper invoked there is declared on
the same terms as an interpreter: `jq` today, and a name joins it only on the
same evidence — a helper the catalog already treats as declarable, unambiguous
as a bare word in shell text. A coreutil from the POSIX toolbox never does; it
is on every host we support and declaring it would be noise in hundreds of
actions.

## Why

The declaration is the only pre-flight signal. `emisar pack info` LookPaths
exactly what `requires.binaries` names and the readiness check reports it, so an
undeclared helper is invisible until dispatch: the pack installs cleanly, the
action appears in the catalog, an operator or an LLM selects it, and it fails
then — on a Debian slim image, an Alpine host, or a hardened build, at the same
version and the same trusted hash that works everywhere else.

`docker` shipped exactly that. `docker.compose_config` builds its whole
structured result with jq (`scripts/compose_config.sh`, `jq -r "$filter"` in
`bounded_json_list` plus the final `jq -nce`) and `docker.compose_images` parses
its inventory with it, while `pack.yaml` declared only `docker` and `bash`. It
was the one pack in that gap: 28 packs run jq from their own shell source and
the other 27 already declared it, which is why the rule is the catalog's own
convention rather than a guess about which helpers matter.

## Good

```yaml
requires:
  binaries:
    - docker
    - bash
    # docker.compose_config and docker.compose_images build their structured
    # results with it; undeclared, both fail at dispatch on a host without it.
    - jq
```

## Bad

```yaml
requires:
  binaries: [docker, bash]   # scripts/compose_config.sh runs jq
```

The action's own script text is the dependency the manifest left out.

## Sweep

For each pack, read the shell source its actions actually run — the packaged
script behind `execution.script.path` and the `-c` program in
`execution.command.argv` — and check every helper it invokes against
`requires.binaries`. A **comment** naming a helper is not a dependency: the
scripts that run jq are also the ones that explain it, and
`scripts/compose_config.sh` carries three such comments, one of them about a
builtin it deliberately avoids. A mention in an action `description`, a
`setup` note, or a `test/cases.yaml` harness command is not one either — only
the shell text an action dispatches counts.

## Enforcement

`validatePackScriptHelperBinaries`
(`tools/internal/devtool/pack_interpreter.go`, chained from
`validatePackActionLints` and run by `./run check packs`) reads each action's
shell source through `actionShellSource` and reports a helper it runs that the
manifest does not declare.

`scriptRunsCommand` looks for the name in a COMMAND position, not every mention
of it. A word-boundary match anywhere outside single quotes attributed a
dependency to `printf '%s\n' "jq unavailable"`, which invokes only printf — and
the diagnostic an action prints when a helper is MISSING is the one place the
name is guaranteed to appear without being run. The supported static forms are
the whole contract:

- A command position is the start of the program and the word after `\n`, `;`,
  `|`, `&`, `&&`, `||`, `(`, `)`, a `$( … )` or backtick opening, one of the
  prefix words (`if`, `then`, `elif`, `else`, `do`, `while`, `until`, `!`,
  `time`, `{`, `}`), or a `NAME=value` assignment prefix. Every later word in
  that simple command is an argument.
- A single-quoted span is literal text — where a jq FILTER is authored, never a
  command — and is skipped whole.
- A double-quoted span is NOT skipped: a `$( … )` or backtick inside one opens a
  real command scope, which is how `detail="$(jq -r . "$f")"` keeps its
  attribution, while the quoted text itself stays part of one word.
- `#` opens a comment only at the start of a word and only outside double
  quotes.
- A command word may be quoted (`'jq' .`) or a path (`/usr/bin/jq .`).

It is a token scanner, not a shell, and deliberately does not model: a command
supplied to another command (`xargs jq`, `sh -c 'jq …'`), a command named by
expansion (`${JQ:-jq}`), a heredoc body, a `case` pattern, or a redirection
target in front of the command word (`> jq cmd`). The first two under-report and
the rest over-report; no shipped pack uses any of them, and an author who needs
one declares the helper by hand.

`TestValidatePackScriptHelperBinaries` pins the fixtures: an undeclared helper
in a packaged script fires, a declared one passes, a commented mention alone
does not fire, a commented mention beside a real call still does, a name inside
an identifier (`jq_filter=`) is not a call, and an inline `-c` program is read
like a script. Command position has its own rows on both sides — a quoted
diagnostic argument, a bare diagnostic argument and foreign filter text are not
calls; a substitution inside a double-quoted word, a quoted command word, an
assignment-prefixed call and a call after `if !` are.
`TestScriptHelperBinaryLintCoversTheShippedCatalog` runs the check over every
shipped pack and then, with the declarations ignored, asserts the detector still
attributes jq to all 28 packs that run it — a check that detected nothing would
pass the catalog too.

Related references:
[jq filters stay on core jq](packs-jq-filters-stay-on-core-jq.md) and
[suggestions use explicit evidence](packs-suggestions-use-explicit-evidence.md)
— `requires.binaries` says what an installed pack needs to execute and never
becomes a `detect` signal.
