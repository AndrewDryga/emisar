//go:build !windows

package devtool

import (
	"os"
	"path/filepath"
	"testing"
)

// A loop box starts with an empty database volume and no gate suite uses the
// focused partition, so a focused run that skipped setup waited forever for a
// database nothing created.
func TestFocusedPortalTestsPrepareTheirDatabaseFirst(t *testing.T) {
	app := testApp(t)
	app.Portal = filepath.Join(app.Root, "portal")
	if err := os.MkdirAll(filepath.Join(app.Portal, "apps", "emisar", "test"), 0o755); err != nil {
		t.Fatal(err)
	}
	calls := filepath.Join(t.TempDir(), "calls")
	bin := t.TempDir()
	mix := "#!/bin/sh\nprintf '%s %s\\n' \"${PWD##*/}\" \"$*\" >> '" + calls + "'\n"
	if err := os.WriteFile(filepath.Join(bin, "mix"), []byte(mix), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	// Its own partition, so this run never queues behind a real one's lock.
	env := map[string]string{"MIX_TEST_PARTITION": "focused" + filepath.Base(t.TempDir())}

	if err := app.portalTests(t.Context(), env, []string{"apps/emisar/test/one_test.exs"}, false); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(calls)
	if err != nil {
		t.Fatal(err)
	}
	want := "portal deps.compile\nemisar ecto.create --quiet\nemisar ecto.migrate --quiet\nemisar test test/one_test.exs\n"
	if string(got) != want {
		t.Fatalf("mix calls =\n%s\nwant\n%s", got, want)
	}
}
