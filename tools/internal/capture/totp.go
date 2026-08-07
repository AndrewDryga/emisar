// Package capture holds what the provider screenshot rigs share.
//
// The four rigs under tools/cmd/*-capture drive four different admin consoles,
// but they sign in the same way, and each had grown its own copy of the pieces
// that involves. Three of them carried a separate RFC 6238 implementation, and
// the copies had drifted where it matters: two stripped hyphens from the shared
// secret before decoding and one did not, so the same secret an operator pasted
// from a provider's setup screen worked in two rigs and failed in the third.
package capture

import (
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base32"
	"encoding/binary"
	"fmt"
	"strings"
	"time"
)

// totpStep is RFC 6238's default 30-second time step. Every provider these rigs
// sign into issues codes on it.
const totpStep = 30

// TOTPCode returns the current six-digit code for a base32 shared secret, so no
// phone is in the loop when a rig signs in.
func TOTPCode(secret string) (string, error) {
	return totpCodeAt(secret, time.Now())
}

func totpCodeAt(secret string, now time.Time) (string, error) {
	// Providers present the secret in human-readable groups — spaces in some
	// consoles, hyphens in others — and neither is part of the base32 alphabet.
	normalized := strings.ToUpper(strings.NewReplacer(" ", "", "-", "").Replace(secret))
	key, err := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(normalized)
	if err != nil {
		return "", fmt.Errorf("decode TOTP secret: %w", err)
	}

	counter := make([]byte, 8)
	binary.BigEndian.PutUint64(counter, uint64(now.Unix()/totpStep))

	mac := hmac.New(sha1.New, key)
	mac.Write(counter)
	sum := mac.Sum(nil)

	offset := sum[len(sum)-1] & 0x0f
	value := binary.BigEndian.Uint32(sum[offset:offset+4]) & 0x7fffffff
	return fmt.Sprintf("%06d", value%1_000_000), nil
}
