//go:build !windows

package devtool

import (
	"bytes"
	"os"
	"strings"
	"syscall"
	"testing"
)

// The key decides which runs serialize, so it has to resolve the database the
// same way portal/config/test.exs does. Getting it wrong is silent both ways:
// too coarse and unrelated runs queue behind each other, too fine and the
// collision this lock exists to stop goes right on happening.
func TestPortalTestDatabaseKeyMirrorsTestConfigResolution(t *testing.T) {
	for _, test := range []struct {
		name string
		env  map[string]string
		want string
	}{
		{
			name: "defaults match config's localhost and 5432",
			env:  map[string]string{},
			want: "localhost:5432/emisar_test",
		},
		{
			name: "PGHOST and PGPORT win",
			env:  map[string]string{"PGHOST": "db", "PGPORT": "5432"},
			want: "db:5432/emisar_test",
		},
		{
			name: "the service URL supplies the port when PGPORT is absent",
			env:  map[string]string{"COOP_SERVICE_DB_URL": "postgres://postgres@localhost:31372/x"},
			want: "localhost:31372/emisar_test",
		},
		{
			name: "PGPORT beats the service URL, as config reads it first",
			env: map[string]string{
				"PGPORT":              "25201",
				"COOP_SERVICE_DB_URL": "postgres://postgres@localhost:31372/x",
			},
			want: "localhost:25201/emisar_test",
		},
		{
			name: "a partition names a different database, so it takes its own lock",
			env:  map[string]string{"PGPORT": "31372", "MIX_TEST_PARTITION": "2"},
			want: "localhost:31372/emisar_test2",
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			for _, name := range []string{"PGHOST", "PGPORT", "COOP_SERVICE_DB_URL", "MIX_TEST_PARTITION"} {
				t.Setenv(name, "")
			}
			if got := portalTestDatabaseKey(test.env); got != test.want {
				t.Fatalf("portalTestDatabaseKey = %q, want %q", got, test.want)
			}
		})
	}
}

// Two runs against one database must not overlap; two against different
// databases must not wait on each other. Both directions matter — a lock that
// serializes everything would make every unrelated run pay for this.
func TestPortalTestLockSerializesOnlyMatchingDatabases(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
	output := &bytes.Buffer{}
	app := &App{Root: t.TempDir(), Out: output}

	held, err := app.portalTestLock(map[string]string{"PGPORT": "31372"})
	if err != nil {
		t.Fatalf("portalTestLock: %v", err)
	}

	// A different database is a different lock file, so it is free immediately.
	other, err := app.portalTestLock(map[string]string{"PGPORT": "25201"})
	if err != nil {
		t.Fatalf("a run against another database was made to wait: %v", err)
	}
	releasePortalTestLock(other)

	// The same database is genuinely held. Probing non-blockingly keeps the test
	// from hanging on the very contention it is checking for.
	probe, err := os.OpenFile(held.Name(), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		t.Fatalf("opening the lock file: %v", err)
	}
	defer probe.Close()
	if err := syscall.Flock(int(probe.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err == nil {
		t.Fatal("a second run took a lock the first still holds")
	}

	releasePortalTestLock(held)
	if err := syscall.Flock(int(probe.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatalf("the lock stayed held after release: %v", err)
	}
	_ = syscall.Flock(int(probe.Fd()), syscall.LOCK_UN)

	if strings.Contains(output.String(), "waiting:") {
		t.Fatalf("an uncontended run announced a wait: %q", output.String())
	}
}
