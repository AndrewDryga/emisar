//go:build windows

package fsutil

// SyncDirectory is a no-op on Windows. os.File.Sync on a directory maps to
// FlushFileBuffers, which requires a writable handle that os.Open cannot
// obtain for directories. The file itself is synced before every rename.
func SyncDirectory(_ string) error { return nil }
