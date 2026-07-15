//go:build darwin || dragonfly || freebsd || linux || netbsd || openbsd || solaris

package main

import (
	"os"
	"syscall"
	"testing"
)

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
