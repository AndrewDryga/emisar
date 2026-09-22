//go:build darwin || dragonfly || freebsd || illumos || linux || netbsd || openbsd

package audit

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

const journalLockWait = 5 * time.Second

// Lock a stable sidecar, never the journal inode that rotation replaces. Keep
// the file after unlocking: removing it would let peers lock different inodes.
// Do not use the action context; a cancelled action still needs its receipt.
func lockJournal(path string) (*os.File, error) {
	owner, err := journalOwner(path)
	if err != nil {
		return nil, err
	}
	f, err := openJournalFile(path+".lock", os.O_CREATE|os.O_RDWR, owner)
	if err != nil {
		return nil, fmt.Errorf("audit: open journal lock: %w", err)
	}
	deadline := time.Now().Add(journalLockWait)
	for {
		err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return f, nil
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) {
			_ = f.Close()
			return nil, fmt.Errorf("audit: acquire journal lock: %w", err)
		}
		if time.Now().After(deadline) {
			_ = f.Close()
			return nil, fmt.Errorf("audit: journal busy after %s; retry when the other writer finishes: %w", journalLockWait, err)
		}
		time.Sleep(25 * time.Millisecond)
	}
}

func journalOwner(path string) (os.FileInfo, error) {
	info, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return os.Stat(filepath.Dir(path))
	}
	if err == nil && !info.Mode().IsRegular() {
		return nil, fmt.Errorf("audit: journal is not a regular file")
	}
	return info, err
}

// The runner and a root CLI must both be able to reopen the journal after
// either rotates it. Newly created files inherit the existing journal's owner
// (or its directory's owner on first use), not the root CLI's identity.
func openJournalFile(path string, flags int, owner os.FileInfo) (*os.File, error) {
	flags |= syscall.O_NOFOLLOW | syscall.O_NONBLOCK
	created := false
	var f *os.File
	var err error
	if flags&os.O_CREATE != 0 {
		f, err = os.OpenFile(path, flags|os.O_EXCL, 0o600)
		created = err == nil
		if os.IsExist(err) {
			f, err = os.OpenFile(path, flags&^os.O_CREATE, 0)
		}
	} else {
		f, err = os.OpenFile(path, flags, 0)
	}
	if err != nil {
		return nil, err
	}
	info, err := f.Stat()
	if err == nil && !info.Mode().IsRegular() {
		err = fmt.Errorf("audit: %s is not a regular file", filepath.Base(path))
	}
	if err == nil && created && owner != nil && os.Geteuid() == 0 {
		stat := owner.Sys().(*syscall.Stat_t)
		err = f.Chown(int(stat.Uid), int(stat.Gid))
	}
	if err == nil && info.Mode().Perm() != 0o600 {
		err = f.Chmod(0o600)
	}
	if err != nil {
		_ = f.Close()
		return nil, err
	}
	return f, nil
}
