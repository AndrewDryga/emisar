# Rule: applied migrations are frozen

**Rule.** Never edit, rename, or delete a migration that production ran; add a
new migration. A migration confirmed as unrun remains greenfield: correct or
delete it in place.

**Why.** Production runs each migration once. Editing an applied file changes
fresh databases but does not update a database that already ran it, so schemas
diverge.

Git history is not deployment history: `main` creates a plan and a founder
applies it later. Check the applied production migrations before changing an
existing file. Do not preserve an unrun mistake with staging migrations,
compatibility bridges, or a repair chain merely because it was committed.

Keep migration operations proportional to real data. Check current row counts
before adding a large backfill or destructive delete. Use a concurrent index or
batching only when actual table size or traffic makes a blocking operation
material; do not build a multi-migration rollout for a tiny or empty table.
