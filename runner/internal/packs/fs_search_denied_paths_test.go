package packs

import "testing"

// fs-search's crown-jewel deny list must contain a directory SUBTREE, not just
// the exact directory inode. The runner enforces `denied_paths` by EXACT match
// (validation/args.go pathInList) and only `denied_prefixes` does subtree
// matching (prefixInList) — so a directory listed under denied_paths blocks the
// bare dir but NOT the files inside it (finding M5). Before the fix, every
// fs-search reader (risk:low, no approval) let /root/.ssh/id_rsa,
// /etc/ssh/ssh_host_ed25519_key, /etc/ssl/private/server.key and
// /etc/sudoers.d/90-custom through — the exact paths the pack advertises as
// blocked. These load the REAL pack from packs/ and drive the engine's dispatch
// seam (validation.Validate) to prove the containment boundary is now real.

// Every fs-search action takes a `path` arg (the first arg in each schema, so
// its denial fires before any other required arg is reached).
var fsSearchActions = []string{
	"fs.count_lines",
	"fs.du_top",
	"fs.file_type",
	"fs.find_by_name",
	"fs.find_large_files",
	"fs.find_recent_modified",
	"fs.find_setuid",
	"fs.find_world_writable",
	"fs.grep_file",
	"fs.grep_recursive",
	"fs.head_file",
	"fs.ls_long",
	"fs.sha256_file",
	"fs.stat_path",
	"fs.tail_file",
}

// A file UNDER each crown-jewel directory must be rejected by the subtree
// (denied_prefixes) rule — the exact-match denied_paths list never covered
// these, which was the whole defect.
var fsSearchDeniedPrefixFiles = []string{
	"/root/.ssh/id_rsa",
	"/etc/ssh/ssh_host_ed25519_key",
	"/etc/ssl/private/server.key",
	"/etc/sudoers.d/90-custom",
}

// The single-file crown jewels stay on the exact-match denied_paths list.
var fsSearchDeniedExactFiles = []string{
	"/etc/shadow",
	"/etc/gshadow",
	"/etc/sudoers",
	"/proc/kcore",
}

func TestFsSearch_CrownJewelSubtreesDenied(t *testing.T) {
	reg := loadRealLibrary(t)

	for _, id := range fsSearchActions {
		for _, p := range fsSearchDeniedPrefixFiles {
			err := dispatchValidate(t, reg, id, map[string]any{"path": p})
			rejected(t, err, "path", "denied_prefixes")
		}
		for _, p := range fsSearchDeniedExactFiles {
			err := dispatchValidate(t, reg, id, map[string]any{"path": p})
			rejected(t, err, "path", "denied_paths")
		}
	}
}

// The `path` arg is `type: path`, so the runner filepath.Clean-s the value
// before it is both deny-checked AND substituted into the command. That closes
// two escapes at once: a `..` traversal to a crown jewel is canonicalized and
// rejected here, and — because the same cleaned value is what reaches find —
// the recursive actions' `-path` prune can't be dodged with `//`/`..` (find
// would otherwise print raw-prefixed paths that miss the single-slash -path
// literals).
func TestFsSearch_DotDotTraversalCanonicalizedAndDenied(t *testing.T) {
	reg := loadRealLibrary(t)

	for _, id := range fsSearchActions {
		// /var/log/../../etc/shadow -> Clean -> /etc/shadow (exact deny).
		err := dispatchValidate(t, reg, id, map[string]any{"path": "/var/log/../../etc/shadow"})
		rejected(t, err, "path", "denied_paths")
		// /var/log/../../root/.ssh/id_rsa -> Clean -> /root/.ssh/id_rsa (subtree deny).
		err = dispatchValidate(t, reg, id, map[string]any{"path": "/var/log/../../root/.ssh/id_rsa"})
		rejected(t, err, "path", "denied_prefixes")
	}
}

// The deny rules must not over-reject a benign path. Each action gets its other
// required args filled with valid values so validation reaches — and passes —
// the path check.
func TestFsSearch_BenignPathAccepted(t *testing.T) {
	reg := loadRealLibrary(t)

	extra := map[string]map[string]any{
		"fs.find_by_name":   {"glob": "*.log"},
		"fs.grep_file":      {"pattern": "ERROR"},
		"fs.grep_recursive": {"pattern": "ERROR"},
	}

	for _, id := range fsSearchActions {
		args := map[string]any{"path": "/var/log/syslog"}
		for k, v := range extra[id] {
			args[k] = v
		}
		accepted(t, dispatchValidate(t, reg, id, args))
	}
}
