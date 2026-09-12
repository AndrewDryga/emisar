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
manifest does not declare. `scriptRunsCommand` matches the bare word outside
comments and outside single-quoted spans, so a jq filter's own text and a
comment explaining jq are both skipped while the invocation beside them is not.

`TestValidatePackScriptHelperBinaries` pins the fixtures: an undeclared helper
in a packaged script fires, a declared one passes, a commented mention alone
does not fire, a commented mention beside a real call still does, a name inside
an identifier (`jq_filter=`) is not a call, and an inline `-c` program is read
like a script. `TestScriptHelperBinaryLintCoversTheShippedCatalog` runs the
check over every shipped pack and then, with the declarations ignored, asserts
the detector still attributes jq to all 28 packs that run it — a check that
detected nothing would pass the catalog too.

Related references:
[jq filters stay on core jq](packs-jq-filters-stay-on-core-jq.md) and
[suggestions use explicit evidence](packs-suggestions-use-explicit-evidence.md)
— `requires.binaries` says what an installed pack needs to execute and never
becomes a `detect` signal.
