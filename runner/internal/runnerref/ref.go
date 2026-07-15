// Package runnerref defines the public, generation-bound runner reference used
// in signed MCP dispatches. The display name is portal-owned context; the
// suffix is derived from the runner's durable local external ID and is the
// portion the runner can verify independently.
package runnerref

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strings"
)

const suffixLength = 32

// Suffix returns the first 128 bits of SHA-256(externalID), encoded as lowercase
// hex. It is a stable generation identifier, not a secret or authorization
// credential.
func Suffix(externalID string) (string, error) {
	if externalID == "" {
		return "", fmt.Errorf("runnerref: external id is empty")
	}
	digest := sha256.Sum256([]byte(externalID))
	return hex.EncodeToString(digest[:])[:suffixLength], nil
}

// Matches reports whether ref has a well-formed public shape and its suffix is
// derived from externalID. The display-name prefix is deliberately not checked:
// the portal owns that operator-facing name, while the runner independently
// owns only its durable external ID.
func Matches(ref, externalID string) bool {
	separator := strings.LastIndexByte(ref, '~')
	if separator <= 0 || strings.ContainsRune(ref[:separator], '~') || separator+1+suffixLength != len(ref) {
		return false
	}
	for _, char := range ref[separator+1:] {
		if (char < '0' || char > '9') && (char < 'a' || char > 'f') {
			return false
		}
	}
	want, err := Suffix(externalID)
	return err == nil && ref[separator+1:] == want
}

// ContainsLocal reports whether exactly one signed ref names this runner
// generation. More than one matching display prefix is ambiguous and refused.
func ContainsLocal(refs []string, externalID string) bool {
	matches := 0
	for _, ref := range refs {
		if Matches(ref, externalID) {
			matches++
		}
	}
	return matches == 1
}
