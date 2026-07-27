# CI decides what a workstation cannot

**Rule.** Some surfaces are judged by CI and only CI. For those, a change is not
done when the local gate is green — it is done when the CI job is green. Do not
mark the task done, and do not fold the work into a commit you would defend,
until you have read that job.

Surfaces where a workstation returns a false pass:

| Surface | What the local run cannot see |
|---|---|
| `packs/*/test/` | uid ownership and AppArmor (Docker Desktop's VM masks both), and any startup race a machine with spare cores wins |
| `.github/workflows/` | the runner's toolchain and the state actions leave behind — a buildx driver selected for the rest of the job has its own image store |
| `dev/test-packs/` | both of the above, for every pack at once |

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
# Push for the verdict, then finish the task.
git push -u origin <branch> && gh pr create ...   # read the matrix
git rebase -i origin/main                          # fold fixes into their commit
coop tasks done <id>
```

**❌ Bad**

```
./run test packs            # 266/266 PASS on a Mac
coop tasks done <id>        # the class this touched was never judged
```

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
host. Sweep signal: a task moved to `99_done/` whose commit touches one of the
surfaces above with no CI run read for it, and a fix commit whose message
repairs the commit immediately before it.
