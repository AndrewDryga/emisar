package packs

import "testing"

// bind.named_checkzone takes a `file` arg (`named-checkzone <zone> <file>`). The
// old `^/[a-zA-Z0-9_./\-]{1,512}$` pattern anchored only to `/`, so ANY absolute
// path passed and — with no allowed/denied paths — applyPathValidation
// early-returned and the runner's Clean+EvalSymlinks jail never ran.
// named-checkzone PARSES the file and quotes offending lines back in its errors
// (a filtered read oracle over any runner-readable secret), and it is risk:low
// (no approval gate). The fix scopes `file` to BIND's standard zone roots via
// allowed_prefixes, which engages the jail. Drive the real dispatch seam: the
// shipped example path passes, a plain out-of-scope path is rejected, and a `..`
// traversal that still matches the charset is cleaned back and caught by the
// prefix jail.
func TestDispatch_BindNamedCheckzone_ScopedToZoneRoots(t *testing.T) {
	reg := loadRealLibrary(t)
	const id = "bind.named_checkzone"
	const zone = "example.com"

	// The action's own example zone file, under /etc/bind — in scope.
	accepted(t, dispatchValidate(t, reg, id, map[string]any{"zone": zone, "file": "/etc/bind/db.example.com"}))
	// RHEL's zone root — also in scope.
	accepted(t, dispatchValidate(t, reg, id, map[string]any{"zone": zone, "file": "/var/named/db.example.com"}))

	// A plain out-of-scope absolute path — the arbitrary-file read the finding
	// named — is rejected before it can reach named-checkzone.
	rejected(t, dispatchValidate(t, reg, id, map[string]any{"zone": zone, "file": "/etc/shadow"}), "file", "allowed_prefixes")

	// A `..` traversal passes the charset pattern but the jail cleans it back to
	// /etc/shadow and rejects it as outside the allowed prefix.
	rejected(t, dispatchValidate(t, reg, id, map[string]any{"zone": zone, "file": "/etc/bind/../../etc/shadow"}), "file", "allowed_prefixes")
}
