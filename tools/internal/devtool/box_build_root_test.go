package devtool

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBoxBuildRootIsPerCheckoutAndKeepsSharedToolBinaries(t *testing.T) {
	shared := t.TempDir()
	if err := os.WriteFile(filepath.Join(shared, "tailwind-linux-arm64-4.3.3"), []byte("tw"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(shared, "dev"), 0o755); err != nil {
		t.Fatal(err)
	}

	keyedFor := func(root string) string {
		t.Helper()
		app := testApp(t)
		app.Root = root
		t.Setenv("COOP_BOX", "1")
		t.Setenv("MIX_BUILD_ROOT", shared)
		t.Setenv(sharedBuildRootEnv, "")
		if err := app.isolateBoxBuildRoot(); err != nil {
			t.Fatal(err)
		}
		// A nested ./run keys from the remembered shared root, not the keyed one.
		if err := app.isolateBoxBuildRoot(); err != nil {
			t.Fatal(err)
		}
		return os.Getenv("MIX_BUILD_ROOT")
	}

	first := keyedFor("/work/emisar")
	second := keyedFor("/work/emisar-forks/portal-b")
	if first == second || !strings.HasPrefix(first, filepath.Join(shared, "checkouts")+string(os.PathSeparator)) {
		t.Fatalf("build roots = %q, %q; want distinct dirs under %s/checkouts", first, second, shared)
	}
	if target, err := os.Readlink(filepath.Join(first, "tailwind-linux-arm64-4.3.3")); err != nil || target != filepath.Join(shared, "tailwind-linux-arm64-4.3.3") {
		t.Fatalf("tool binary link = %q, %v", target, err)
	}
	if _, err := os.Lstat(filepath.Join(first, "dev")); !os.IsNotExist(err) {
		t.Fatalf("the shared build env directory leaked into the keyed root: %v", err)
	}
}

func TestBoxBuildRootLeavesTheHostAlone(t *testing.T) {
	app := testApp(t)
	t.Setenv("MIX_BUILD_ROOT", "/somewhere")
	if err := app.isolateBoxBuildRoot(); err != nil {
		t.Fatal(err)
	}
	if got := os.Getenv("MIX_BUILD_ROOT"); got != "/somewhere" {
		t.Fatalf("host MIX_BUILD_ROOT changed to %q", got)
	}
}
