package packs

import "testing"

// ssl-local's key/cert readers list /root/.ssh under denied_paths, but the
// runner enforces denied_paths by EXACT match (validation/args.go pathInList)
// and only denied_prefixes does subtree matching (prefixInList) — so a directory
// listed under denied_paths blocked the bare dir but NOT the SSH keys inside it
// (finding n18, the ssl-local analog of fs-search's M5). Before the fix, every
// ssl reader (risk:low, no approval) let /root/.ssh/id_rsa through the pattern
// and past the deny list. The four shadow-family entries are single FILES, so
// exact-match denied_paths is correct for those and they stay put. These load
// the REAL pack from packs/ and drive the engine's dispatch seam
// (validation.Validate) to prove the /root/.ssh subtree is now contained.

// Every ssl reader with a filesystem path arg names it `path` (verify_chain,
// which takes `cert`, does not carry the /root/.ssh deny list and is out of
// scope for this finding).
var sslPathActions = []string{
	"ssl.key_modulus",
	"ssl.cert_text",
	"ssl.cert_expiry",
	"ssl.cert_fingerprint",
	"ssl.find_certs",
	"ssl.pkcs12_info",
}

// A file UNDER the /root/.ssh subtree must be rejected by the denied_prefixes
// rule — the exact-match denied_paths list never covered it, which was the whole
// defect.
var sslDeniedPrefixFiles = []string{
	"/root/.ssh/id_rsa",
	"/root/.ssh/id_ed25519",
}

// The shadow-family single-file crown jewels stay on the exact-match
// denied_paths list.
var sslDeniedExactFiles = []string{
	"/etc/shadow",
	"/etc/gshadow",
	"/etc/shadow-",
	"/etc/gshadow-",
}

func TestSslLocal_SshSubtreeDenied(t *testing.T) {
	reg := loadRealLibrary(t)

	for _, id := range sslPathActions {
		for _, p := range sslDeniedPrefixFiles {
			err := dispatchValidate(t, reg, id, map[string]any{"path": p})
			rejected(t, err, "path", "denied_prefixes")
		}
		for _, p := range sslDeniedExactFiles {
			err := dispatchValidate(t, reg, id, map[string]any{"path": p})
			rejected(t, err, "path", "denied_paths")
		}
	}
}

// The `path` value is filepath.Clean-ed before both the deny check and command
// substitution, so a `..` traversal to the SSH subtree is canonicalized and
// rejected rather than slipping past the single-slash deny entry.
func TestSslLocal_DotDotTraversalCanonicalizedAndDenied(t *testing.T) {
	reg := loadRealLibrary(t)

	for _, id := range sslPathActions {
		// /etc/ssl/../../root/.ssh/id_rsa -> Clean -> /root/.ssh/id_rsa (subtree deny).
		err := dispatchValidate(t, reg, id, map[string]any{"path": "/etc/ssl/../../root/.ssh/id_rsa"})
		rejected(t, err, "path", "denied_prefixes")
		// /etc/ssl/../shadow -> Clean -> /etc/shadow (exact deny).
		err = dispatchValidate(t, reg, id, map[string]any{"path": "/etc/ssl/../shadow"})
		rejected(t, err, "path", "denied_paths")
	}
}

// The deny rules must not over-reject a benign cert path — the other half of
// every gate.
func TestSslLocal_BenignPathAccepted(t *testing.T) {
	reg := loadRealLibrary(t)

	for _, id := range sslPathActions {
		accepted(t, dispatchValidate(t, reg, id, map[string]any{"path": "/etc/ssl/certs/server.crt"}))
	}
}
