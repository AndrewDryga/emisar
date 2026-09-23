# Rule: a pack starts from research and a verified SUT, and goes deep

**Rule.** Build a new pack, or expand one, in this order:

1. **Learn what the product is for.** Find out who runs it, what it does in
   their stack, and what its operators do with it day to day: check health,
   find out why something is slow or failing, inspect configuration and
   capacity, and apply the routine fixes.
2. **Research how operators work with it.** Read the vendor's API and CLI
   references and the operational tools and runbooks people actually use.
   List the common use cases, the commands or endpoints behind each, how
   they authenticate, and which versions they need.
3. **Verify against a real instance before writing actions.** When the
   product runs in a container, write the test SUT first (`test/compose.yaml`,
   plus a `test/Dockerfile` when the runner needs the product's client). Run
   the basic CLI commands and API calls against it by hand, and confirm the
   paths, flags, authentication, and the fields and errors each one returns.
   Every action starts from a command that already worked. A hosted-only
   product gets a fixture and a governed live read instead, as
   [remote actions need fixture and live read evidence](packs-remote-actions-need-fixture-and-live-read-evidence.md)
   describes.
4. **Build it deep and detailed.** Cover at least what an operator needs at
   the basic and mid level: health and status, inventory, configuration,
   metrics and errors, and the routine fixes. Give each action an accurate,
   verb-led description and an honest risk tier. Ship a pack only when a
   customer would genuinely use it.

Stop short of what is hard to add. An action that needs a multi-node cluster,
a licensed edition, a heavy SUT, or a multi-step workflow with its own
recovery waits for a customer request. Record in the task what was left out
and why.

**Why.** A pack is worth installing only if it answers the questions an
operator actually has. Reads that only prove the API answers give an agent
nothing to work with during an incident, and a customer who installs them
concludes the catalog is shallow. Actions written from documentation alone
ship wrong paths, flags, and response fields that one real call would have
revealed, and the behavior harness then fails on them later and more slowly.
The opposite failure is chasing every corner of a product: the hardest
actions cost the most to build and test and are the ones customers use least,
so they wait until someone asks.

**Good.** `clickhouse` covers server metrics and errors, slow and failed
queries, parts and partitions, merges and mutations, replication and Keeper
health, detached parts, the distributed-send backlog, and backups, plus narrow
fixes (`OPTIMIZE`, `KILL QUERY`, `SYSTEM RELOAD CONFIG`, replica operations).
Its behavior cases run against a real ClickHouse server with an embedded
Keeper.

**Bad.** Five reads that prove the API answers (health, version, two counts)
and nothing an operator reaches for when something breaks. An action whose
endpoint or flag was never run before its behavior case. A replica-rebalancing
workflow that needs a three-node SUT, built before any customer asked for it.

**Sweep.** For each new or expanded pack, compare its action list with the
product's operational surface: health, status, inventory, configuration,
metrics, errors, and routine fixes. Check the task log for the research notes,
the SUT commands that were run by hand, and the list of what was deferred.

**Enforced.** Review only. The behavior harness proves that each action works,
but no check can judge whether a pack covers what operators need, so the task
log is the evidence. A workstation may not fit a heavy SUT;
[CI decides what a workstation cannot](shared-ci-decides-what-a-workstation-cannot.md).
