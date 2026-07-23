package devtool

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func TestServeLockRejectsSecondOwnerAndReleases(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
	app := testApp(t)
	first, err := app.serveLock(43123, "http://localhost:43123")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := app.serveLock(43123, "http://localhost:43123"); err == nil || !strings.Contains(err.Error(), "pid") {
		t.Fatalf("second lock error = %v", err)
	}
	first.Close()
	second, err := app.serveLock(43123, "http://localhost:43123")
	if err != nil {
		t.Fatalf("released lock stayed held: %v", err)
	}
	second.Close()
}

func TestChangedPortalFilesIncludesUntrackedSource(t *testing.T) {
	root := t.TempDir()
	for _, args := range [][]string{{"init", "-q"}, {"config", "user.email", "test@example.com"}, {"config", "user.name", "Test"}} {
		command := exec.Command("git", args...)
		command.Dir = root
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, output)
		}
	}
	if err := os.WriteFile(filepath.Join(root, "README.md"), []byte("test\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	command := exec.Command("git", "add", "README.md")
	command.Dir = root
	if err := command.Run(); err != nil {
		t.Fatal(err)
	}
	command = exec.Command("git", "commit", "-qm", "initial")
	command.Dir = root
	if err := command.Run(); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "portal", "apps", "emisar_web", "lib", "probe.ex")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("defmodule Probe do\nend\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	app := New(root, bytes.NewBuffer(nil), &bytes.Buffer{}, &bytes.Buffer{})
	paths, err := app.changedPortalFiles(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(paths) != 1 || paths[0] != "portal/apps/emisar_web/lib/probe.ex" {
		t.Fatalf("changed paths = %v", paths)
	}
}

func TestStagedCheckFormatsTheIndexNotTheWorkingTree(t *testing.T) {
	root := t.TempDir()
	for _, args := range [][]string{
		{"init", "-q"},
		{"config", "user.email", "test@example.com"},
		{"config", "user.name", "Test"},
	} {
		command := exec.Command("git", args...)
		command.Dir = root
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, output)
		}
	}
	path := filepath.Join(root, "probe.go")
	if err := os.WriteFile(path, []byte("package probe\nfunc Value( )int{return 1}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	command := exec.Command("git", "add", "probe.go")
	command.Dir = root
	if err := command.Run(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("package probe\n\nfunc Value() int { return 1 }\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	app := New(root, strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{})
	err := app.stagedCheck(t.Context())
	if err == nil || !strings.Contains(err.Error(), "staged Go files are not formatted") {
		t.Fatalf("staged check error = %v", err)
	}
}

func TestRunCapturedRejectsPollution(t *testing.T) {
	app := testApp(t)
	err := app.runCaptured(context.Background(), "fixture", app.Root, nil, "sh", "-c", "printf 'warning: noisy\\n'")
	if err == nil || !strings.Contains(err.Error(), "polluted") {
		t.Fatalf("pollution error = %v", err)
	}
}

func TestParseEnvFileTreatsShellSyntaxAsData(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sandbox.env")
	if err := os.WriteFile(path, []byte("# comment\nexport PADDLE_API_KEY='key_sdbx_123'\nTOKEN=$(not-executed)\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	values, err := parseEnvFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if values["PADDLE_API_KEY"] != "key_sdbx_123" || values["TOKEN"] != "$(not-executed)" {
		t.Fatalf("values = %#v", values)
	}
}

func TestPortalGateRequiresDatabaseURLInCI(t *testing.T) {
	t.Setenv("CI", "true")
	t.Setenv("DATABASE_URL", "")
	app := New(t.TempDir(), strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{})
	err := app.portalFeedback(context.Background(), "gate", []string{"portal"})
	if err == nil || !strings.Contains(err.Error(), "requires DATABASE_URL") {
		t.Fatalf("portal gate error = %v", err)
	}
}

func TestMergedEnvReplacesExistingValue(t *testing.T) {
	t.Setenv("EMISAR_ENV_FIXTURE", "old")
	env := mergedEnv(map[string]string{"EMISAR_ENV_FIXTURE": "new"})
	matches := 0
	for _, entry := range env {
		if entry == "EMISAR_ENV_FIXTURE=new" {
			matches++
		}
		if entry == "EMISAR_ENV_FIXTURE=old" {
			t.Fatalf("old value remains in environment: %v", env)
		}
	}
	if matches != 1 {
		t.Fatalf("new value appeared %d times", matches)
	}
}

func TestSelectPackServicesUsesDirectAndAliasedServices(t *testing.T) {
	available := map[string]bool{"postgres": true, "redis": true, "k3s": true, "k3s-kubeconfig": true, "runner-tools": true}
	got := selectPackServices([]string{"postgres", "kubernetes", "linux-core"}, available)
	want := []string{"k3s", "k3s-kubeconfig", "postgres"}
	if !slices.Equal(got, want) {
		t.Fatalf("services = %v, want %v", got, want)
	}
}

func TestPackTestComposeProjectIsStableAndWorkspaceSpecific(t *testing.T) {
	first := packTestComposeProject("/tmp/a")
	if first != packTestComposeProject("/tmp/a") || first == packTestComposeProject("/tmp/b") {
		t.Fatalf("compose projects are not stable and distinct: %q", first)
	}
}

func TestTargetsLocalPortRejectsOtherNgrokTargets(t *testing.T) {
	for _, target := range []string{"http://localhost:4000", "http://127.0.0.1:4000"} {
		if !targetsLocalPort(target, 4000) {
			t.Fatalf("rejected local target %q", target)
		}
	}
	for _, target := range []string{"http://localhost:5000", "http://example.com:4000", "not-a-url"} {
		if targetsLocalPort(target, 4000) {
			t.Fatalf("accepted unrelated target %q", target)
		}
	}
}

func TestBrowserCacheRootIsStableAndWorkspaceSpecific(t *testing.T) {
	cache := t.TempDir()
	first := browserCacheRoot(cache, "/tmp/workspace-a", 42000)
	if first != browserCacheRoot(cache, "/tmp/workspace-a", 42000) {
		t.Fatal("browser cache identity is not stable")
	}
	if first == browserCacheRoot(cache, "/tmp/workspace-b", 42000) {
		t.Fatal("browser cache identity aliases two workspaces on the same port")
	}
}
