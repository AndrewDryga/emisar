# Rule: shell pipelines fail on source errors

**Rule.** A pack action whose `/bin/sh -c` program pipes a command into `tail`,
`head`, `sort`, or `awk` must guarantee that a failure of the *source* command
fails the action. Guard the input before the pipeline — `[ -r "$path" ]` for a
file, `[ -d "$path" ]` for a directory — or capture the source's status and
`exit` with it. A read action that finds nothing must be distinguishable from a
read action whose input was not there.

**Why.** A shell pipeline exits with the status of its **last** command. In
`grep -E ' 5[0-9][0-9] ' "$1" | tail -n 100`, `tail` succeeds whatever `grep`
did, so a missing or unreadable file produces exit `0` with empty stdout and one
line on stderr. The action is recorded as a successful run that found nothing.

That is a false all-clear, and these are exactly the `low`, no-approval reads an
operator or an LLM uses to answer "are we serving errors?". "No 5xx in the last
100 lines" and "there is no access log on this host" are opposite facts about
production and must not share a result. The same masking hides an unreachable
broker, a dead cluster, and — in `nginx -T` — a config that does not parse.

**Do not reach for `set -o pipefail`.** `grep` exits `1` when it matches
nothing, which is the *good* outcome for an error-log search. Under `pipefail` a
clean log becomes a failed action, trading a false all-clear for a false alarm.
It is also not POSIX `sh`. Guard the input instead.

**Good.**

```sh
[ -r "$1" ] || { echo "access log not readable: $1" >&2; exit 1; }
grep -E ' 5[0-9][0-9] ' "$1" | tail -n 100
```

```sh
dump=$(nginx -T 2>&1); status=$?
printf '%s\n' "$dump" | head -800
exit $status
```

Pick the input before consuming it, so a fallback actually runs:

```sh
if [ -r /var/log/mail.log ]; then log=/var/log/mail.log
elif [ -r /var/log/maillog ]; then log=/var/log/maillog
else echo "no readable mail log at /var/log/mail.log or /var/log/maillog" >&2; exit 1
fi
grep -F "$P" "$log" | head -2000
```

**Bad.**

```sh
grep -E ' 5[0-9][0-9] ' "$1" | tail -n 100
```

Exits `0` when `$1` does not exist, reporting "no 5xx".

```sh
grep -F "$P" /var/log/mail.log 2>/dev/null | head -2000 || grep -F "$P" /var/log/maillog | head -2000
```

Worse: `head` makes the left side exit `0` unconditionally, so the `||` fallback
is dead code and a host with only `/var/log/maillog` is reported as having no
matching mail.

```sh
tail -n 100 "$1" | awk '{print $1}' | sort | uniq -c | sort -nr | head -20
```

`tail` fails on a missing log; `head` reports success and "no traffic".

**Scope.** The obligation is strongest where the source reads a path — an
operator-supplied arg, an `execution.env` path, or a hard-coded log — because a
host that simply logs elsewhere is the common case, not an exotic one. It
applies equally to a source that contacts a remote (`kubectl`, `nomad`, a
cluster CLI) whose failure means "cannot see the target". Pipelines fed by a
local always-present enumerator (`ps`, `lsmod`, `ss`, `journalctl`) are exempt:
there is no meaningful failure to mask, and their empty output is self-evident.

**How it's enforced.** `validatePackPipelineFailures` in
`tools/internal/devtool/pack_pipeline.go`, run per pack by both
`./run gate packs` and `./run pack check <name>`, alongside the curl-side check
in [the HTTP response rule](packs-http-actions-fail-on-response-errors.md). It
flags a `/bin/sh -c` program whose first pipeline segment reads a path with no
preceding guard. Its scan is quote-aware, because the alternation in
`grep -E '(a|b)' "$1" | tail` is regex syntax rather than the shell pipe — the
naive scan silently passed exactly the action this rule came from. Exemptions
are listed by action ID in `pipelineSourceExemptActions` with a reason.

**Sweep.** `rg -l '\| *tail |\| *head ' packs/*/actions/*.yaml`, then read each
program's first segment: does it open a file or contact a remote, and can that
fail without failing the action?
