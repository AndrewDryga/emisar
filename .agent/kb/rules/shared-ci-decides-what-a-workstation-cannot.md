# CI decides what a workstation cannot

**Rule.** Some surfaces are judged by CI and only CI. A green local run on those
is iteration feedback, never a verdict, so never *claim* one of them verified on
the strength of a workstation run — say what the local run covered and that the
Linux matrix is what decides the rest. Finishing and committing the task does not
wait on that job; when the matrix later finds something, fix it as its own change.

Surfaces where a workstation returns a false pass:

| Surface | What the local run cannot see |
|---|---|
| `packs/*/test/` | uid ownership and AppArmor (Docker Desktop's VM masks both), and any startup race a machine with spare cores wins |
| `.github/workflows/` | the runner's toolchain and the state actions leave behind — a buildx driver selected for the rest of the job has its own image store |
| `dev/test-packs/` | both of the above, for every pack at once |
| `docker-compose.yml` | who owns a bind-mounted file. Desktop remaps it to the container user; on CI it stays the job user, and anything that validates ownership refuses it. Every runner config now reaches its container by being copied into a named volume as root (`runner-config-init`, `runner-runbook-init`, `signing-init`) — a config a runner reads directly from `./dev/...` is the sweep signal |

**Why.** Three fixtures shipped broken in one change because a green local run
read as a verdict. rabbitmq's health check raced the entrypoint writing
`.erlang.cookie`: thirteen of fourteen cases lost that race on a four-core
runner and none lost it on a twelve-core workstation. zookeeper's readiness
proved loopback while its cases dial the bridge. haproxy's client image resolved
its base against the registry because `setup-buildx-action` leaves a
container-driver builder selected. None of the three could fail locally, so each
was "verified" and each was wrong — and the fixes landed as follow-up commits,
leaving two commits in `main` that would fail CI if checked out.

The trap is not ignorance of this; the rule card for pack fixtures already said
a workstation cannot judge that class. The trap is finishing a long local run,
reading `266/266 PASS`, and treating the number as the answer to a question it
was never asked.

**✅ Good**

```
./run test packs            # 266/266 PASS on a Mac
# "Cases pass locally; uid ownership, AppArmor and startup races are the
#  Linux matrix's call." Then commit and finish the task.
```

**❌ Bad**

```
./run test packs            # 266/266 PASS on a Mac
# "Verified."               # the class this touched was never judged
```

**Judge a CI change on the constraint that actually binds.** The shared client
image is cached in CI despite costing more wall clock than rebuilding it — the
build pulls eight server images to extract one binary each, and the registry, not
the clock, is what runs out. Removing the cache on a timing argument traded two
registry round trips per row for nine and turned one occasional failure into
three in a single run. Measure the binding constraint before optimising the
visible one.

**A shared quota is a CI-only limit too.** Docker Hub rate-limits anonymous
pulls per address, and a runner pool shares addresses, so matrix width is bounded
by the registry rather than by CPU. Twelve concurrent rows returned
`unauthorized: authentication required` and a connection timeout twice in five
runs; a workstation pulling one image at a time never sees it. Raise matrix width
in steps and read the next few runs for registry errors before trusting it.

**One green run is one sample.** A suite this shape is flaky until shown
otherwise, so a single green CI run is evidence, not proof. Re-run the job that
failed before merging on its recovery — zookeeper went green, then failed a
re-run of the same commit, then failed again on a third fix. Three readiness
fixes each moved its failure to a different case before the honest answer turned
out to be that the pack keeps its slower readiness.

**How it's enforced.** `./run test packs` ends a passing run by naming what this
host could not decide — file ownership, AppArmor, startup races — and pointing
at the Linux matrix. It reports the limits rather than failing, because
iterating locally is the point; what it refuses to do is let the pass count
stand as a verdict. `packTestHostBlindSpots` is unit-tested against a
workstation, Docker Desktop on Linux, a roomy Linux host, and a runner-shaped
host. Sweep signal: a claim that one of the surfaces above is verified, backed
only by a workstation run.
