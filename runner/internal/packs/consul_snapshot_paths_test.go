package packs

import "testing"

// consul's snapshot_save/restore/inspect each take a `path` arg
// (`consul snapshot save|restore|inspect {{path}}`). The old
// `^/[a-zA-Z0-9_./\-]{1,512}\.snap$` pattern anchored only to `/` and a `.snap`
// suffix, so ANY absolute .snap-named path passed and — with no allowed/denied
// paths — applyPathValidation early-returned and the runner's Clean+EvalSymlinks
// jail never ran. save WRITES a .snap file at the given path as the runner user
// (drop `/etc/cron.d/x.snap` anywhere writable); restore LOADS cluster state from
// an arbitrary .snap path; inspect (risk:low, no approval) READS one. The fix
// scopes each `path` to Consul's data dir + standard backup roots via
// allowed_prefixes, which engages the jail while keeping the .snap suffix. Drive
// the real dispatch seam: an in-scope path passes, a plain out-of-scope path is
// rejected, and a `..` traversal that still matches the charset is cleaned back
// and caught by the prefix jail.
func TestDispatch_ConsulSnapshotPaths_ScopedToBackupRoots(t *testing.T) {
	reg := loadRealLibrary(t)

	for _, id := range []string{"consul.snapshot_save", "consul.snapshot_restore", "consul.snapshot_inspect"} {
		t.Run(id, func(t *testing.T) {
			// The documented example root — in scope.
			accepted(t, dispatchValidate(t, reg, id, map[string]any{"path": "/var/backups/consul-pre-migration.snap"}))
			// Consul's data dir — also in scope.
			accepted(t, dispatchValidate(t, reg, id, map[string]any{"path": "/var/lib/consul/snap.snap"}))

			// A plain out-of-scope absolute path (still .snap-suffixed) — the
			// arbitrary write/read the finding named — is rejected before consul.
			rejected(t, dispatchValidate(t, reg, id, map[string]any{"path": "/etc/cron.d/pwn.snap"}), "path", "allowed_prefixes")

			// A `..` traversal passes the charset pattern but the jail cleans it
			// back to /etc/cron.d/pwn.snap and rejects it as outside the prefix.
			rejected(t, dispatchValidate(t, reg, id, map[string]any{"path": "/var/backups/../../etc/cron.d/pwn.snap"}), "path", "allowed_prefixes")
		})
	}
}
