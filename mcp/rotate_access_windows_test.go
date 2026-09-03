//go:build windows

package main

import (
	"fmt"
	"os"
	"syscall"
	"testing"
)

// The Windows CI lanes are the judge here: a peer bridge holding the credential
// lock must degrade to the read-only path, never fail startup or a request.
func TestIsCredentialWriteUnavailable_Windows(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want bool
	}{
		{name: "peer holds the lock past credentialLockWait", err: errorSharingViolation, want: true},
		{name: "wrapped sharing violation", err: fmt.Errorf("lock credential state: %w", errorSharingViolation), want: true},
		{name: "permission denied", err: os.ErrPermission, want: true},
		{name: "access denied errno", err: syscall.ERROR_ACCESS_DENIED, want: true},
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

func TestIsCredentialWriteDegradable_WrapsTheSharingViolation(t *testing.T) {
	err := &credentialWriteAccessError{err: fmt.Errorf("lock credential state: %w", errorSharingViolation)}
	if !isCredentialWriteDegradable(err) {
		t.Fatal("a peer holding the credential lock must be degradable, not a hard failure")
	}
}
