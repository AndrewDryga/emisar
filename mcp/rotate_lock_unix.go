//go:build darwin || dragonfly || freebsd || linux || netbsd || openbsd || solaris

package main

import (
	"errors"
	"fmt"
	"os"
	"syscall"
	"time"
)

// credentialLockWait bounds the wait for a peer bridge to release the credential
// lock. A blocking LOCK_EX waited forever, and it is taken while the process-wide
// state mutex is held — the same mutex the serve loop reads transport state
// under — so one stalled peer stopped this bridge reading frames at all rather
// than merely delaying one request. Three MCP clients against one state file is
// the documented setup, not an exotic one, and a home directory on NFS or SMB
// makes a stall ordinary. The Windows adapter has always bounded this; the
// platforms we actually ship now agree with it.
const credentialLockWait = 5 * time.Second

func lockCredentialFile(path string) (func(), error) {
	// O_NOFOLLOW refuses a symlink planted at the lock path: withLock validates
	// the credential directory before calling this, so with the parent trusted
	// the final component is the only place a same-uid attacker could redirect
	// the open. Every other credential open is already symlink-safe.
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return nil, err
	}
	deadline := time.Now().Add(credentialLockWait)
	for {
		err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			break
		}
		// EWOULDBLOCK means a peer holds it. Anything else — notably ENOLCK on a
		// filesystem that does not implement locks — passes straight through to
		// isCredentialWriteUnavailable, which decides whether to degrade to the
		// read-only credential path instead of failing the process.
		if !errors.Is(err, syscall.EWOULDBLOCK) || time.Now().After(deadline) {
			file.Close()
			return nil, err
		}
		time.Sleep(25 * time.Millisecond)
	}
	return func() {
		if err := syscall.Flock(int(file.Fd()), syscall.LOCK_UN); err != nil {
			fmt.Fprintf(os.Stderr, "emisar-mcp: unlock credential state: %v\n", err)
		}
		_ = file.Close()
	}, nil
}
