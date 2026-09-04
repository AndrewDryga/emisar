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

**Two source shapes, two fixes.** Guard the input when the source opens a
*path*: `grep`'s exit code is overloaded (1 = clean no-match), so its status
cannot be propagated blindly, and the guard is what works around that overload.

A source that runs a *command* — `kubectl`, `nomad`, `jmap`, a cluster CLI — has
no such overload: its own status is the truth and the pipe is the only thing
discarding it. Propagate, via the capture shape above. Capture rather than a
live pipe, for two reasons beyond the exit code: `head`'s early exit can no
longer SIGPIPE the source (`jmap -histo:live` always exceeds `head -50`, so a
live pipe would fail every *successful* run), and a mid-pipeline `grep`
no-match stops mattering. Command substitution takes stdout only — leave stderr
flowing, it is the evidence channel.

"Empty output is a legitimate answer" is not a reason to skip propagation — it
is why propagation is *correct*: the tool exits 0 on a genuinely empty result
and non-zero when it cannot see the target, which is exactly the distinction
being lost. Nor should a source's stderr be discarded: `conntrack -L
2>/dev/null` hid the one line that separates "this host has no NAT entries"
from "the runner lacks CAP_NET_ADMIN".

Pipelines fed by a local always-present enumerator (`ps`, `lsmod`, `ss`) need
nothing: there is no meaningful failure to mask, and their empty output is
self-evident. `dmesg` and `journalctl` are not in that class: kernel policy,
journal ACLs, or an unavailable journal can make them fail, so capture their
output successfully before filtering or use the tool's native limit flag.

**When propagation genuinely cannot work,** record an exemption with the reason
rather than shipping a guard that enforces nothing:

- the source exits 0 on failure (`gdb -batch` returns 0 when the attach fails),
- its non-zero is benign (`lsof` exits 1 for "no matching files"),
- an unbounded stream makes capture impossible and `head` SIGPIPEs the source
  by design (`conntrack -L | head -1000`) — reach for a cheap same-privilege
  precondition probe instead,
- a same-subsystem precondition already runs first (`conntrack -C` under
  `set -e` needs the same netlink privileges as `-L`).

**How it's enforced.** `validatePackPipelineFailures` in
`tools/internal/devtool/pack_pipeline.go`, run per pack by both
`./run gate packs` and `./run pack check <name>`, alongside the curl-side check
in [the HTTP response rule](packs-http-actions-fail-on-response-errors.md). The
shared lint loader follows the action paths declared by `pack.yaml`; a nested
or renamed action cannot fall outside this check, and an unreferenced YAML file
is not executable input. The pipeline lint flags a source led by a path reader
(`pipelineFileReaders`) or a target-dependent command
(`pipelineRemoteSources`) with no preceding guard. Exemptions are listed by
action ID in `pipelineSourceExemptActions` with a stated reason.

Two things the checker learned the hard way, both worth keeping:

- **Its scan is quote-aware.** The alternation in `grep -E '(a|b)' "$1" | tail`
  is regex syntax, not the shell pipe; reading it as the pipe truncated the
  segment before `"$1"` and silently passed the exact action this rule came
  from. Fixture tests alone did not catch that — regressing a real action
  through `./run pack check` did.
- **It reads packaged scripts, not just `-c` programs.** `nomad.event_snapshot`
  hid in a `kind: script` file through the first pass.
- **It unwraps grouped source fallbacks.** In `{ dmesg || journalctl; } | tail`,
  the group is still one fallible pipeline source. A successful `tail` must not
  turn failure of both producers into an empty all-clear.
- **A guard covers only the path its pipeline reads.** `[ -d /var/spool/postfix ]`
  is no guard for `cat /var/spool/postfix/$q | wc`, and `[ -d "$SP" ]` proves
  nothing about `du "$SP"/*`: a guarded parent or sibling used to satisfy the
  check, which is how `postfix.queue_counts` and `py.site_packages_du` shipped
  their false all-clears. The lint now matches each guard to an operand the
  source is handed (a bare `$var` resolves through the program's assignments),
  and `|| exit` / `|| {` alone no longer count as a guard of anything.

**Sweep.** The manifest-driven lint is authoritative. As a quick review aid for
the repository's conventional layout, run `rg -l '\| *tail |\| *head '
packs/*/actions/*.yaml`, then read each program's first segment: does it open a
file or contact a remote, and can that fail without failing the action?
