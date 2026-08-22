# Docs command examples show the real output

**Rule.** A docs command block shows the output the operator will read — at least
the part they act on — under the command, in the muted output style. The output
text comes from the command's real print format: read the source (`Printf`
formats, tabwriter layout, exact wording) or run the command; never invent a
shape. Long output is elided with a lone `…` line; values may be illustrative
(versions, hashes, names consistent with the page's running example) but every
line must be one the real command could print, byte-shape included. Color output
lines only where the CLI itself colors them (diff `-`/`+`, warnings), using the
site's semantic tones.

**Why.** A command with no output teaches half the interaction: the reader
cannot picture what success looks like, what to write down, or how the next step
connects ("check the hash against the one `pack list` printed" only lands if the
page shows that line). Invented output is worse than none — an operator who sees
different text assumes the docs are stale or their install is broken.

## ✅ Good

```
$ sudo emisar pack update redis

  redis                  v0.2.3 → v0.2.4 updated
1 updated, 0 up to date, 0 not in registry, 0 failed.
Reloaded the runner — it re-reads packs and re-advertises to the control plane.
```

Every line matches `packupdate.go`'s formats, including the `%-22s` padding and
the real reload sentence. The rollback example elides the long setup summary
with `…` between the `installed` line and the reload line.

## ❌ Bad

- `$ sudo emisar pack diff redis` with nothing under it — the reader has never
  seen a pack diff and cannot picture the callouts the prose describes.
- Output written from memory: `Pack redis updated successfully.` when the CLI
  prints `  redis                  v0.2.3 → v0.2.4 updated`.
- "Fixing" the CLI's real grammar in the sample (`1 file changed` when the code
  prints `1 files changed`) — verbatim wins; fix the CLI if it bothers you.

**When a bare command is fine.** Output that is empty, a bare exit, or noise the
reader never acts on (a `systemctl restart`, an `export`) — and alternate-form
commands in a block whose primary form already shows the output.

**How it's enforced.** Review; `marketing_test.exs` pins load-bearing output
lines per page (e.g. the pack-diff `! risk escalated` callout) so a sample
cannot silently disappear.
