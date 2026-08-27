// Package fsutil holds filesystem helpers for the runner's local state.
package fsutil

import (
	"bufio"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
)

// SecureMkdirAll creates dir (and any parents) with perm and — unlike a bare
// os.MkdirAll — also TIGHTENS an already-existing dir whose permissions are
// looser than perm. os.MkdirAll applies its mode only when it creates the dir,
// so a data dir an operator or systemd pre-created world-readable (0755) keeps
// those bits even though the runner writes 0600 secret files (token, audit,
// nonce store) into it. We clear any bit looser than perm — for the usual
// 0o750 that's group-write plus all of world (0o027) — but NEVER add bits, so
// an operator's stricter 0700 is preserved.
//
// Tightening is best-effort: the secret files are 0600 regardless, so a dir the
// runner can't chmod (it isn't the owner — e.g. a root-owned, group-shared data
// dir) warns rather than refusing to start. A failure to *create* the dir is
// still fatal.
func SecureMkdirAll(dir string, perm os.FileMode) error {
	if err := os.MkdirAll(dir, perm); err != nil {
		return err
	}

	info, err := os.Stat(dir)
	if err != nil {
		return err
	}

	current := info.Mode().Perm()
	// Bits looser than perm: 0o777 &^ 0o750 == 0o027 (group-write + world-rwx).
	if tightened := current &^ (0o777 &^ perm.Perm()); tightened != current {
		if err := os.Chmod(dir, tightened); err != nil {
			slog.Warn("could not tighten data directory permissions; ensure it is not world-accessible",
				"dir", dir, "have", current.String(), "want", tightened.String(), "error", err)
		}
	}
	return nil
}

// WriteRecord replaces the held lock file's contents — the connect daemon
// records its PID there so sibling CLI invocations (pack install/update/
// uninstall) can signal it to reload. Only meaningful while the lock is held;
// the flock itself is the liveness proof, the record just names the holder.
func (l *FileLock) WriteRecord(data []byte) error {
	if l == nil || l.file == nil {
		return os.ErrInvalid
	}
	if err := l.file.Truncate(0); err != nil {
		return err
	}
	if _, err := l.file.WriteAt(data, 0); err != nil {
		return err
	}
	return l.file.Sync()
}

// ReplaceFile durably replaces path with whatever write produces: a
// dot-prefixed CreateTemp sibling (a fixed temp name could be a symlink
// planted by anything able to write in the directory), 0600, a buffered
// writer handed to the callback, fsync, close, rename, then a directory
// sync. The temp file never survives an error. Serialization, size caps,
// and caller vocabulary stay with the caller; this owns only the replace
// mechanics, so the runner's durable secrets and state share one reviewed
// implementation.
func ReplaceFile(path string, write func(io.Writer) error) error {
	dir := filepath.Dir(path)
	if err := SecureMkdirAll(dir, 0o750); err != nil {
		return err
	}
	f, err := os.CreateTemp(dir, "."+filepath.Base(path)+".tmp-")
	if err != nil {
		return fmt.Errorf("create temp for %s: %w", filepath.Base(path), err)
	}
	tmp := f.Name()
	discard := func(err error) error {
		_ = f.Close()
		_ = os.Remove(tmp)
		return err
	}
	if err := f.Chmod(0o600); err != nil {
		return discard(fmt.Errorf("secure temp for %s: %w", filepath.Base(path), err))
	}
	buffered := bufio.NewWriter(f)
	if err := write(buffered); err != nil {
		return discard(err)
	}
	if err := buffered.Flush(); err != nil {
		return discard(fmt.Errorf("write temp for %s: %w", filepath.Base(path), err))
	}
	if err := f.Sync(); err != nil {
		return discard(fmt.Errorf("sync temp for %s: %w", filepath.Base(path), err))
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("close temp for %s: %w", filepath.Base(path), err)
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("activate %s: %w", filepath.Base(path), err)
	}
	if err := SyncDirectory(dir); err != nil {
		return fmt.Errorf("sync directory of %s: %w", filepath.Base(path), err)
	}
	return nil
}
