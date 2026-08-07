package devtool

import (
	"crypto/sha256"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"syscall"
)

// portalTestLock serializes portal test runs that share a database.
//
// portal/config/test.exs names the database emisar_test$MIX_TEST_PARTITION, and
// nothing sets that variable — not this tool, not CI — so every run against one
// Postgres uses the same database and the same Ecto sandbox. That is fine until a
// run reaches ecto.migrate with a pending migration: its DDL takes ACCESS
// EXCLUSIVE, a concurrent run's queries block behind it, and DBConnection's query
// timeout then cancels them. The suite reports 57014 query_canceled and
// client-exited noise, the output guard fails, and the failure names whichever
// tests happened to be running rather than anything that is wrong with them.
//
// Waiting is the cheap side of that trade: the second run pays the first run's
// duration once, instead of a person re-reading a suite's worth of false
// failures. See .agent/kb/portal-tests-share-one-database-per-workspace.md.
func (a *App) portalTestLock(env map[string]string) (*os.File, error) {
	dir, err := portalTestLockDir()
	if err != nil {
		return nil, err
	}
	key := sha256.Sum256([]byte(portalTestDatabaseKey(env)))
	lock, err := os.OpenFile(filepath.Join(dir, fmt.Sprintf("%x.lock", key[:8])), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err == nil {
		return lock, nil
	}
	// Say why the run is sitting still. An unexplained pause before the first
	// phase reads as a hang, which is how people learn to reach for Ctrl-C.
	fmt.Fprintf(a.Out, "waiting: another portal test run holds %s\n", portalTestDatabaseKey(env))
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		lock.Close()
		return nil, err
	}
	return lock, nil
}

func releasePortalTestLock(lock *os.File) {
	_ = syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	_ = lock.Close()
}

// portalTestLockDir is scoped to the user, not the workspace: two checkouts can
// point at one database, and they have to take the same lock.
func portalTestLockDir() (string, error) {
	root := os.Getenv("XDG_RUNTIME_DIR")
	if root == "" {
		root = os.TempDir()
	}
	dir := filepath.Join(root, fmt.Sprintf("emisar-dev-%d", os.Getuid()), "portal-test")
	return dir, os.MkdirAll(dir, 0o700)
}

// portalTestDatabaseKey mirrors how portal/config/test.exs resolves the database,
// so two runs serialize exactly when they would collide and never otherwise.
// Keep the two in step: a resolution step added there belongs here as well.
func portalTestDatabaseKey(env map[string]string) string {
	lookup := func(name string) string {
		if value := env[name]; value != "" {
			return value
		}
		return os.Getenv(name)
	}
	host := lookup("PGHOST")
	if host == "" {
		host = "localhost"
	}
	port := lookup("PGPORT")
	if port == "" {
		if raw := lookup("COOP_SERVICE_DB_URL"); raw != "" {
			if parsed, err := url.Parse(raw); err == nil {
				port = parsed.Port()
			}
		}
	}
	if port == "" {
		port = "5432"
	}
	return fmt.Sprintf("%s:%s/emisar_test%s", host, port, lookup("MIX_TEST_PARTITION"))
}
