// Package fsutil holds filesystem helpers for the runner's local state.
package fsutil

import (
	"log/slog"
	"os"
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
