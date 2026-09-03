//go:build darwin || dragonfly || freebsd || linux || netbsd || openbsd || solaris

package main

import (
	"fmt"
	"os"
	"syscall"
	"testing"
)

// The Windows classifier carries the same table for its own contention errno;
// the two platforms must agree on what degrades, or one of them fails startup
// and every request over a peer bridge holding the lock.
func TestIsCredentialWriteUnavailable_Unix(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want bool
	}{
		{name: "peer holds the lock past credentialLockWait", err: syscall.EWOULDBLOCK, want: true},
		{name: "wrapped contention", err: fmt.Errorf("lock credential state: %w", syscall.EWOULDBLOCK), want: true},
		{name: "permission denied", err: os.ErrPermission, want: true},
		{name: "network home directory without flock", err: syscall.ENOLCK, want: true},
		{name: "a real persistence failure is not degradable", err: os.ErrInvalid, want: false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := isCredentialWriteUnavailable(test.err); got != test.want {
				t.Fatalf("isCredentialWriteUnavailable(%v) = %t, want %t", test.err, got, test.want)
			}
		})
	}
}

func TestInitializeCredentialState_ReadOnlyFilesystemFallback(t *testing.T) {
	current := testAPIKey(37)
	store := newCredentialStoreAt(t.TempDir(), testEndpointOrigin, keyPrefix(current))
	store.ops.chmod = func(string, os.FileMode) error { return syscall.EROFS }

	b := newRotationTestBridge(store, current)
	readOnly, err := b.initializeCredentialState()
	if err != nil {
		t.Fatalf("initialize read-only filesystem credential state: %v", err)
	}
	if !readOnly || !b.credentialReadOnly || b.apiKey != current || b.pendingKey != "" {
		t.Fatalf("read-only filesystem fallback state: readOnly=%t current=%q pending=%q", readOnly, b.apiKey, b.pendingKey)
	}
}
