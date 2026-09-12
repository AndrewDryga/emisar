# Rule: every published action-id namespace is grandfathered

**Rule.** An action id's namespace is its pack id, and that rule binds **new
packs**. It is not a licence to rewrite the catalog: **every namespace already
published is grandfathered, whatever shape it has.** Renaming a published action
id is a founder decision, never a tidy-up sweep — so a namespace audit that finds
one of the ids below reports nothing. Author the next pack under its pack id and
leave the published ones alone.

**Why a rename is a founder call, not tidy-up.** A published action id is not
internal spelling. Three consumers key on the exact string:

- **Operator policy overrides are globs matched against the action id.**
  `Policies.evaluate/2` ends at
  `Glob.match_compiled?(matcher, action_id)`
  (`portal/apps/emisar/lib/emisar/policies.ex:1178`), and the grammar is anchored
  with `*` as the only wildcard (`portal/apps/emisar/lib/emisar/policies/glob.ex`).
  An account that wrote `rmq.*` → require approval, or a deny override on
  `zk.delete_*`, silently stops matching the moment the namespace moves. The
  failure is in the unsafe direction: a **deny** override that no longer matches
  turns a denied action back into an allowed one, and nothing in the rename tells
  the operator their policy went quiet.
- **The published registry is append-only and content-addressed.** A renamed id
  is a new id, not an edit; the old one keeps serving from catalog history
  (`packs/PUBLISHING.md`), so the fleet runs both spellings until every runner
  updates.
- **Operator runbooks, saved approvals, and audit rows** cite ids as written.

That is the same reasoning the `gcp.` note already carried, generalized: it was
never specific to gcp.

**The current-source namespaces (52 pack→namespace pairs that are not the pack
id).** This is what `packs/` publishes *today*, not a history of every namespace
ever published — the grandfather above is wider than this list. Regenerate with
the pack id from each `packs/*/pack.yaml` against the first segment of each
`actions/*.yaml` id.

*A hyphen segment of the pack id (16)* — the qualifier drops:
`apache-httpd`→`httpd.`, `dell-idrac`→`idrac.`, `dell-ipmi`→`ipmi.`,
`dnf-rpm`→`rpm.`, `elixir-beam`→`beam.`, `fs-search`→`fs.`, `git-local`→`git.`,
`java-jvm`→`jvm.`, `linux-core`→`linux.`, `nodejs-pm2`→`pm2.`,
`oidc-jwks`→`oidc.`, `process-forensics`→`forensics.`,
`pure-flasharray`→`pure.`, `ssl-local`→`ssl.`, `systemd-deep`→`systemd.`,
`time-sync`→`time.`

*The vendor's own AWS service names (6)* — because those ARE how operators say
them: `aws-cloudwatch`→`cw.`, `aws-cost`→`ce.`, `aws-ec2`→`ec2.`,
`aws-iam`→`iam.`, `aws-rds`→`rds.`, `aws-s3`→`s3.`

*One shared `gcp.` across ten `gcp-*` packs (10)* — `gcp-billing`,
`gcp-certificates`, `gcp-cloudsql`, `gcp-compute`, `gcp-dns`, `gcp-iam`,
`gcp-load-balancing`, `gcp-monitoring`, `gcp-networking`, `gcp-storage`. This is
the one place the rule is genuinely broken rather than merely abbreviated:
splitting it changes 84 published ids. It would not change search ranking either,
since `gcp-compute.` prefix-matches the query `gcp` exactly as `gcp.` does.

*An invented abbreviation (20)* — grandfathered, never a pattern to copy:
`bunnycdn`→`bunny.`, `clickhouse`→`ch.`, `cloudflare`→`cf.`,
`elasticsearch`→`es.`, `fail2ban`→`f2b.`, `firewall`→`fw.`, `github-cli`→`gh.`,
`hcp-terraform`→`tfc.`, `memcached`→`mc.`, `mongodb`→`mongo.`,
`network-tls`→`net.`, `php-fpm`→`phpfpm.`, `prometheus`→`prom.`,
`python-app`→`py.`, `rabbitmq`→`rmq.`, `terraform-readonly`→`tf.`,
`victorialogs`→`vl.`, `victoriametrics`→`vm.`, `wireguard`→`wg.`,
`zookeeper`→`zk.`

**Retired spellings live outside that list, and no list can close it.** The
bundled catalog artifact still carries `dnf-rpm` 0.1.10 and 0.1.12 with both
`dnf.*` and `rpm.*` ids; 0.1.13 and the current 0.1.14 are `rpm.*` only
(`portal/apps/emisar/priv/packs/catalog.json`). So `dnf.` is a published
namespace that the 52 pairs above do not contain. Catalog history is also a
bounded window — the build keeps the last `DefaultPreviousKept = 3` versions per
pack (`runner/internal/catalog/catalog.go:36`) — so neither current source nor
retained history can enumerate every namespace ever published. The 52 are the
inventory you can regenerate; the grandfather covering **every** published id is
the protection, and it does not depend on listing them.

**Sweep target.** A commit that renames an action id in an already-published pack
on namespace grounds alone, with no founder decision recorded — including a
plausible-looking "consistency" pass over the abbreviations above. A **new** pack
whose namespace is not its pack id is the opposite case and is in scope to fix
before it publishes.

**How it's enforced.** Review, not tooling. No check compares a pack id to its
action namespaces. One would have to allow at least the 52 current pairs above
to stay green, and even then it could only ever read the current tree — not the
published ids the grandfather actually protects. When a pack's namespace does
change by founder decision, it is a contract change: bump `version`, rebuild the bundled
catalog artifact in the same commit
([derived artifacts land with the change](packs-derived-artifacts-land-with-the-change.md)),
and treat the old ids as retired spellings the fleet still runs.
