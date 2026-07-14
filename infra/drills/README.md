# Non-disruptive recovery drills

`run-pitr-iam.sh` restores production to a uniquely named scratch Cloud SQL
instance, creates a temporary scoped IAM database principal and private probe
VM, proves fresh owner-role connections against restored data, deletes only the
scratch IAM database user, and proves fresh connections are then denied. It
trap-deletes every scratch resource and never patches, restarts, or sends traffic
to production.

Run it without arguments first to inspect names and the recovery timestamp.
`--apply` incurs only transient scratch Cloud SQL and `e2-micro` cost. Keep the
terminal attached until cleanup completes. The generated service account exists
before clone creation, so the cleanup command can discover a hard-interrupted
drill even before SQL labels are patched. After any interrupted session, an
operator must run `cleanup-recovery-drills.sh --apply`; it finds generated names
and labels older than 12 hours, refuses ambiguous ownership, and fails closed on
API errors. The janitor is deliberately not scheduled because an unattended
identity able to delete SQL, Compute, IAM, and service-account resources has a
larger blast radius than this occasional supervised drill. Do not close the drill
record until its final inventory is empty.

Image rollback, registry recovery, paging delivery, and load checks use existing
immutable artifacts and public endpoints. They must target scratch instances or
read-only requests; zone-loss exercises never stop a production MIG member.
