package devtool

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/tools/internal/ci"
	"github.com/andrewdryga/emisar/tools/internal/packtest"
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

func TestServePIDReadsTheOwnerFromItsLockFile(t *testing.T) {
	root := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
	app := &App{Root: root}

	if _, err := app.servePID(4000); err == nil {
		t.Fatal("expected an untracked-process error when no lock file exists")
	}

	dir, err := app.serveRuntimeDir()
	if err != nil {
		t.Fatalf("serveRuntimeDir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "serve-4000.lock"), []byte("pid 4321"), 0o600); err != nil {
		t.Fatalf("writing lock: %v", err)
	}

	pid, err := app.servePID(4000)
	if err != nil {
		t.Fatalf("servePID: %v", err)
	}
	if pid != 4321 {
		t.Fatalf("servePID = %d, want 4321", pid)
	}
}

func TestServePIDRejectsAnUnreadableOwner(t *testing.T) {
	root := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
	app := &App{Root: root}
	dir, err := app.serveRuntimeDir()
	if err != nil {
		t.Fatalf("serveRuntimeDir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "serve-4000.lock"), []byte("owned by someone"), 0o600); err != nil {
		t.Fatalf("writing lock: %v", err)
	}

	// A lock file that does not name a pid must never be signalled by guess.
	if _, err := app.servePID(4000); err == nil {
		t.Fatal("expected an untracked-process error for a lock file with no pid")
	}
}

func TestWaitForPortStateGivesUpWithoutBlockingForever(t *testing.T) {
	if err := waitForPortState(context.Background(), 1, true, 50*time.Millisecond); err == nil {
		t.Fatal("expected a timeout waiting for a port nothing listens on")
	}
	// The stop side is the same wait inverted, and it must return at once when
	// the port is already quiet rather than reporting a false failure.
	if err := waitForPortState(context.Background(), 1, false, 50*time.Millisecond); err != nil {
		t.Fatalf("waiting for an already-quiet port: %v", err)
	}
}

func TestInBoxUsesStableCoopMarker(t *testing.T) {
	app := testApp(t)
	t.Setenv("COOP_BOX", "1")
	t.Setenv("COOP_SERVE_URL_4000", "")
	if !app.inBox() {
		t.Fatal("COOP_BOX=1 must identify a box without a serve URL")
	}
}

func TestInBoxRejectsServeURLWithoutMarker(t *testing.T) {
	app := testApp(t)
	t.Setenv("COOP_BOX", "")
	t.Setenv("COOP_SERVE_URL_4000", "http://localhost:4000")
	if app.inBox() {
		t.Fatal("a serve URL alone must not identify the host as a box")
	}
}

func TestWorkspaceEnvUsesForwardedDatabaseOnHost(t *testing.T) {
	app := testApp(t)
	t.Setenv("COOP_BOX", "")
	t.Setenv("PGHOST", "ignored")
	t.Setenv("PGPORT", "9999")
	env := app.workspaceEnv(Workspace{DBPort: 31372})
	if env["PGHOST"] != "localhost" || env["PGPORT"] != "31372" ||
		env["DATABASE_URL"] != "ecto://postgres:postgres@localhost:31372/emisar_dev" {
		t.Fatalf("host database environment = %#v", env)
	}
}

func TestWorkspaceEnvUsesDirectDatabaseInBox(t *testing.T) {
	app := testApp(t)
	t.Setenv("COOP_BOX", "1")
	t.Setenv("PGHOST", "db")
	t.Setenv("PGPORT", "5432")
	env := app.workspaceEnv(Workspace{DBPort: 31372})
	if env["PGHOST"] != "db" || env["PGPORT"] != "5432" ||
		env["DATABASE_URL"] != "ecto://postgres:postgres@db:5432/emisar_dev" {
		t.Fatalf("box database environment = %#v", env)
	}
}

func TestParseServiceForwards(t *testing.T) {
	forwards, err := parseServiceForwards("31372:db:5432,30344:keycloak:8443")
	if err != nil {
		t.Fatal(err)
	}
	want := []serviceForward{
		{listenPort: 31372, target: "db:5432"},
		{listenPort: 30344, target: "keycloak:8443"},
	}
	if !slices.Equal(forwards, want) {
		t.Fatalf("forwards = %#v, want %#v", forwards, want)
	}
	if _, err := parseServiceForwards("31372:db"); err == nil {
		t.Fatal("malformed forward was accepted")
	}
}

func TestServeInvocationSelectsIExWithoutChangingPhoenixArguments(t *testing.T) {
	name, args := serveInvocation(false)
	if name != "mix" || !slices.Equal(args, []string{"phx.server"}) {
		t.Fatalf("normal serve = %s %v", name, args)
	}
	name, args = serveInvocation(true)
	if name != "iex" || !slices.Equal(args, []string{"-S", "mix", "phx.server"}) {
		t.Fatalf("interactive serve = %s %v", name, args)
	}
}

func TestSelectComposeProjectUsesTheExactWorkspaceConfig(t *testing.T) {
	config := filepath.Join(t.TempDir(), "dev", "compose.yml")
	data, err := json.Marshal([]dependencyComposeProject{
		{Name: "other", Status: "running(2)", ConfigFiles: "/tmp/other/compose.yml"},
		{Name: "wanted", Status: "running(2)", ConfigFiles: config + ",/tmp/override.yml"},
	})
	if err != nil {
		t.Fatal(err)
	}
	project, err := selectComposeProject(data, config)
	if err != nil {
		t.Fatal(err)
	}
	if project.Name != "wanted" || project.Status != "running(2)" {
		t.Fatalf("project = %#v", project)
	}
	if _, err := selectComposeProject(data, "/tmp/missing/compose.yml"); !errors.Is(err, errComposeProjectNotFound) {
		t.Fatalf("missing project error = %v", err)
	}
}

func TestGatePhaseReportsDurationAndFailedPhase(t *testing.T) {
	app := testApp(t)
	out := app.Out.(*bytes.Buffer)
	errOut := app.Err.(*bytes.Buffer)
	if err := app.gatePhase("passing fixture", func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "==> passing fixture") || !strings.Contains(out.String(), "<== PASS passing fixture (") {
		t.Fatalf("passing phase output = %q", out.String())
	}
	err := app.gatePhase("failing fixture", func() error { return errors.New("boom") })
	if err == nil || !strings.Contains(err.Error(), `phase "failing fixture" failed after`) || !strings.Contains(err.Error(), "boom") {
		t.Fatalf("failing phase error = %v", err)
	}
	if !strings.Contains(errOut.String(), "<== FAIL failing fixture (") {
		t.Fatalf("failing phase stderr = %q", errOut.String())
	}
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

func TestPortalTestInvocationRoutesFocusedPaths(t *testing.T) {
	portal := t.TempDir()
	tests := []struct {
		name     string
		args     []string
		wantDir  string
		wantArgs []string
	}{
		{
			name:     "emisar child-local path",
			args:     []string{"test/emisar/runs_test.exs:12", "--seed", "1"},
			wantDir:  filepath.Join(portal, "apps", "emisar"),
			wantArgs: []string{"test", "test/emisar/runs_test.exs:12", "--seed", "1"},
		},
		{
			name:     "emisar_web child-local path",
			args:     []string{"test/emisar_web/marketing_test.exs"},
			wantDir:  filepath.Join(portal, "apps", "emisar_web"),
			wantArgs: []string{"test", "test/emisar_web/marketing_test.exs"},
		},
		{
			name:     "umbrella-qualified path",
			args:     []string{"apps/emisar_web/test/emisar_web/marketing_test.exs"},
			wantDir:  filepath.Join(portal, "apps", "emisar_web"),
			wantArgs: []string{"test", "test/emisar_web/marketing_test.exs"},
		},
		{
			name:     "umbrella selector",
			args:     []string{"--stale", "--listen-on-stdin"},
			wantDir:  portal,
			wantArgs: []string{"test", "--stale", "--listen-on-stdin"},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			dir, args, err := portalTestInvocation(portal, test.args)
			if err != nil {
				t.Fatal(err)
			}
			if dir != test.wantDir || !slices.Equal(args, test.wantArgs) {
				t.Fatalf("invocation = (%q, %v), want (%q, %v)", dir, args, test.wantDir, test.wantArgs)
			}
		})
	}
}

func TestPortalTestInvocationRejectsMixedAppPaths(t *testing.T) {
	_, _, err := portalTestInvocation(t.TempDir(), []string{
		"test/emisar/runs_test.exs",
		"test/emisar_web/marketing_test.exs",
	})
	if err == nil || !strings.Contains(err.Error(), "one Portal app") {
		t.Fatalf("mixed paths error = %v", err)
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

func TestStagedCheckFormatsPortalIndexBlobsWithTheirFilename(t *testing.T) {
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
	path := filepath.Join(root, "portal", "apps", "emisar_web", "lib", "probe.heex")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("BAD STAGED BLOB\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	command := exec.Command("git", "add", "portal/apps/emisar_web/lib/probe.heex")
	command.Dir = root
	if err := command.Run(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("formatted working tree\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	bin := filepath.Join(root, "bin")
	if err := os.Mkdir(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	log := filepath.Join(root, "mix.log")
	script := "#!/bin/sh\n" +
		"printf '%s\\n' \"$*\" >> \"$MIX_LOG\"\n" +
		"input=$(cat)\n" +
		"case \"$input\" in *BAD*) echo 'The following files are not formatted:' >&2; exit 1 ;; esac\n"
	if err := os.WriteFile(filepath.Join(bin, "mix"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("MIX_LOG", log)

	app := New(root, strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{})
	err := app.stagedCheck(t.Context())
	if err == nil || !strings.Contains(err.Error(), "staged Portal files are not formatted") {
		t.Fatalf("staged check error = %v", err)
	}
	invocation, readErr := os.ReadFile(log)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if !strings.Contains(string(invocation), "--stdin-filename apps/emisar_web/lib/probe.heex -") {
		t.Fatalf("mix invocation = %q", invocation)
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
	err := app.portalGate(context.Background())
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

func TestPackTestComposeProjectIsInvocationAndCaseSpecific(t *testing.T) {
	first := packTestComposeProject("/tmp/a", "run-1", "postgres", "uptime")
	if first != packTestComposeProject("/tmp/a", "run-1", "postgres", "uptime") ||
		first == packTestComposeProject("/tmp/a", "run-2", "postgres", "uptime") ||
		first == packTestComposeProject("/tmp/b", "run-1", "postgres", "uptime") ||
		first == packTestComposeProject("/tmp/a", "run-1", "mysql", "uptime") ||
		first == packTestComposeProject("/tmp/a", "run-1", "postgres", "connections") {
		t.Fatalf("compose projects are not stable and distinct: %q", first)
	}
}

func TestPackTestComposeEnvUsesCaseIdentity(t *testing.T) {
	plan := packtest.PlanRef{Name: "postfix"}
	image := "emisar-runner-tools:abc123456789"
	nonroot := packTestComposeEnv("/tmp/repo", "run-1", image, plan, "read", nil, "")
	root := packTestComposeEnv("/tmp/repo", "run-1", image, plan, "reload", nil, "root")
	if nonroot["PACKTEST_RUNNER_USER"] != "65532:65532" {
		t.Fatalf("non-root identity = %q", nonroot["PACKTEST_RUNNER_USER"])
	}
	if root["PACKTEST_RUNNER_USER"] != "0:0" {
		t.Fatalf("root identity = %q", root["PACKTEST_RUNNER_USER"])
	}
	if nonroot["COMPOSE_PROJECT_NAME"] == root["COMPOSE_PROJECT_NAME"] {
		t.Fatal("case-specific projects collided")
	}
	if nonroot["PACKTEST_RUNNER_IMAGE"] != "emisar-runner-tools:abc123456789" {
		t.Fatalf("runner image = %q", nonroot["PACKTEST_RUNNER_IMAGE"])
	}
}

func TestPackTestInvocationIDIncludesProcessAndNanoseconds(t *testing.T) {
	now := time.Date(2026, time.July, 23, 14, 5, 6, 789, time.FixedZone("test", -6*60*60))
	if got, want := packTestInvocationID(now, 42), "20260723T200506.000000789Z-42"; got != want {
		t.Fatalf("invocation id = %q, want %q", got, want)
	}
}

func TestPackTestRunnerImageTracksTheDockerfile(t *testing.T) {
	write := func(dockerfile string) string {
		t.Helper()
		root := t.TempDir()
		harness := filepath.Join(root, "dev", "test-packs")
		if err := os.MkdirAll(harness, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(harness, "Dockerfile"), []byte(dockerfile), 0o644); err != nil {
			t.Fatal(err)
		}
		image, err := packTestRunnerImage(root)
		if err != nil {
			t.Fatal(err)
		}
		return image
	}
	original := write("FROM debian:13-slim\n")
	if original != write("FROM debian:13-slim\n") {
		t.Fatalf("same Dockerfile in two checkouts must share one image: %q", original)
	}
	if original == write("FROM debian:13-slim\nRUN apt-get update\n") {
		t.Fatalf("changed Dockerfile must land on a new tag: %q", original)
	}
	if _, err := packTestRunnerImage(t.TempDir()); err == nil {
		t.Fatal("a missing Dockerfile must be an error, not an empty tag")
	}
}

func TestPackTestHostBlindSpots(t *testing.T) {
	tests := []struct {
		name     string
		goos     string
		dockerOS string
		cores    int
		want     int
	}{
		{name: "workstation", goos: "darwin", dockerOS: "Docker Desktop", cores: 12, want: 3},
		{name: "Docker Desktop on Linux", goos: "linux", dockerOS: "Docker Desktop", cores: 4, want: 2},
		{name: "roomy Linux host", goos: "linux", dockerOS: "Ubuntu 24.04.4 LTS", cores: 32, want: 1},
		{name: "CI runner", goos: "linux", dockerOS: "Ubuntu 24.04.4 LTS", cores: 4, want: 0},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := packTestHostBlindSpots(test.goos, test.dockerOS, test.cores); len(got) != test.want {
				t.Fatalf("blind spots = %v, want %d", got, test.want)
			}
		})
	}
	if notice := packTestVerdictNotice([]string{"file ownership"}); !strings.Contains(notice, "authority") ||
		!strings.Contains(notice, "file ownership") {
		t.Fatalf("notice must name the limit and the authority: %q", notice)
	}
}

func TestPackTestNeedsSharedTools(t *testing.T) {
	tests := []struct {
		name    string
		compose string
		want    bool
	}{
		{
			name:    "inherits the shared service",
			compose: "services:\n  fixture:\n    image: redis:8.8.0\n",
			want:    true,
		},
		{
			name:    "tweaks the shared service",
			compose: "services:\n  runner-tools:\n    volumes: [data:/data]\n",
			want:    true,
		},
		{
			name: "derives from the shared image",
			compose: "services:\n  runner-tools:\n    build:\n      context: .\n" +
				"      args:\n        PACKTEST_RUNNER_IMAGE: ${PACKTEST_RUNNER_IMAGE:-emisar-runner-tools:latest}\n",
			want: true,
		},
		{
			name: "replaces the shared image",
			compose: "services:\n  runner-tools:\n    build:\n      context: .\n" +
				"      args:\n        PACKTEST_VERSION: ${PACKTEST_VERSION:-5.0.8}\n",
			want: false,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			dir := t.TempDir()
			if err := os.WriteFile(filepath.Join(dir, "compose.yaml"), []byte(test.compose), 0o644); err != nil {
				t.Fatal(err)
			}
			plans := []packtest.PlanRef{{Name: "fixture", Path: filepath.Join(dir, "cases.yaml")}}
			got, err := packTestNeedsSharedTools(plans)
			if err != nil {
				t.Fatal(err)
			}
			if got != test.want {
				t.Fatalf("needs shared tools = %t, want %t", got, test.want)
			}
		})
	}
}

func TestPackTestNeedsSharedToolsWhenAnyPlanReachesIt(t *testing.T) {
	plan := func(compose string) packtest.PlanRef {
		t.Helper()
		dir := t.TempDir()
		if err := os.WriteFile(filepath.Join(dir, "compose.yaml"), []byte(compose), 0o644); err != nil {
			t.Fatal(err)
		}
		return packtest.PlanRef{Name: "fixture", Path: filepath.Join(dir, "cases.yaml")}
	}
	replaces := plan("services:\n  runner-tools:\n    build:\n      context: .\n      args:\n        PACKTEST_VERSION: x\n")
	inherits := plan("services:\n  fixture:\n    image: redis:8.8.0\n")
	got, err := packTestNeedsSharedTools([]packtest.PlanRef{replaces, inherits})
	if err != nil {
		t.Fatal(err)
	}
	if !got {
		t.Fatal("a selection containing an inheriting plan must build the shared image")
	}
}

func TestSelectPackTestShard(t *testing.T) {
	plans := []packtest.PlanRef{{
		Name:   "cassandra",
		Shards: 2,
		Cases: []packtest.CaseRef{
			{ID: "cassandra.status"}, {ID: "cassandra.info"},
			{ID: "cassandra.ring"}, {ID: "cassandra.version"},
		},
	}}
	selected, err := selectPackTestShard(plans, "2/2")
	if err != nil {
		t.Fatal(err)
	}
	if len(selected) != 1 || len(selected[0].Cases) != 2 ||
		selected[0].Cases[0].ID != "cassandra.info" || selected[0].Cases[1].ID != "cassandra.version" {
		t.Fatalf("selected = %+v", selected[0].Cases)
	}
	if unsharded, err := selectPackTestShard(plans, ""); err != nil || len(unsharded[0].Cases) != 4 {
		t.Fatalf("no shard selector must keep every case: %+v %v", unsharded, err)
	}
	for _, test := range []struct{ shard, want string }{
		{"3/2", "outside 1..2"},
		{"0/2", "outside 1..2"},
		{"1/3", "declares 2 shards"},
		{"1", "<index>/<count>"},
		{"a/2", "is not a number"},
		{"1/b", "is not a number"},
	} {
		if _, err := selectPackTestShard(plans, test.shard); err == nil ||
			!strings.Contains(err.Error(), test.want) {
			t.Fatalf("shard %q error = %v, want %q", test.shard, err, test.want)
		}
	}
	if _, err := selectPackTestShard(append(plans, plans[0]), "1/2"); err == nil ||
		!strings.Contains(err.Error(), "exactly one") {
		t.Fatalf("ambiguous pack error = %v", err)
	}
}

func TestSelectPackTestCaseRequiresOneExactCase(t *testing.T) {
	plans := []packtest.PlanRef{{
		Name: "postgres",
		Cases: []packtest.CaseRef{
			{ID: "postgres.uptime", Action: "postgres.uptime"},
			{ID: "postgres.connections", Action: "postgres.connections"},
		},
	}}
	selected, err := selectPackTestCase(plans, "postgres.uptime")
	if err != nil {
		t.Fatal(err)
	}
	if len(selected) != 1 || len(selected[0].Cases) != 1 ||
		selected[0].Cases[0].ID != "postgres.uptime" {
		t.Fatalf("selected plans = %+v", selected)
	}
	if _, err := selectPackTestCase(plans, "missing"); err == nil ||
		!strings.Contains(err.Error(), "has no case") {
		t.Fatalf("missing case error = %v", err)
	}
	if _, err := selectPackTestCase(append(plans, plans[0]), "postgres.uptime"); err == nil ||
		!strings.Contains(err.Error(), "exactly one") {
		t.Fatalf("ambiguous pack error = %v", err)
	}
}

func TestValidatePackTestVersionInput(t *testing.T) {
	tests := []struct {
		name    string
		compose string
		wantErr string
	}{
		{
			name:    "image",
			compose: "services:\n  fixture:\n    image: caddy:${PACKTEST_VERSION:-2.11.4}${PACKTEST_DIGEST-}\n",
		},
		{
			name: "build arg",
			compose: "services:\n  fixture:\n    build:\n      context: .\n" +
				"      args:\n        PACKTEST_VERSION: ${PACKTEST_VERSION:-2.11.4}\n" +
				"        PACKTEST_DIGEST: ${PACKTEST_DIGEST-}\n",
		},
		{
			name: "mirrorable image build arg",
			compose: "services:\n  fixture:\n    build:\n      context: .\n" +
				"      args:\n        PACKTEST_IMAGE: ${PACKTEST_IMAGE:-caddy:${PACKTEST_VERSION:-2.11.4}${PACKTEST_DIGEST-}}\n",
		},
		{
			name:    "hardcoded",
			compose: "services:\n  fixture:\n    image: caddy:2.11.4\n",
			wantErr: "must default PACKTEST_VERSION",
		},
		{
			name:    "wrong default",
			compose: "services:\n  fixture:\n    image: caddy:${PACKTEST_VERSION:-2.10.2}${PACKTEST_DIGEST-}\n",
			wantErr: "must default PACKTEST_VERSION",
		},
		{
			name:    "missing digest",
			compose: "services:\n  fixture:\n    image: caddy:${PACKTEST_VERSION:-2.11.4}\n",
			wantErr: "must consume PACKTEST_DIGEST",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "compose.yaml")
			if err := os.WriteFile(path, []byte(test.compose), 0o644); err != nil {
				t.Fatal(err)
			}
			err := validatePackTestVersionInput(path, "fixture", "2.11.4")
			if test.wantErr == "" && err != nil {
				t.Fatal(err)
			}
			if test.wantErr != "" && (err == nil || !strings.Contains(err.Error(), test.wantErr)) {
				t.Fatalf("error = %v, want %q", err, test.wantErr)
			}
		})
	}
}

func TestPackTestVersionEnv(t *testing.T) {
	lookup := func(values map[string]string) func(string) (string, bool) {
		return func(key string) (string, bool) {
			value, ok := values[key]
			return value, ok
		}
	}

	env, err := packTestVersionEnv(1, lookup(map[string]string{"PACKTEST_VERSION": "2.10.2"}))
	if err != nil {
		t.Fatal(err)
	}
	if env["PACKTEST_VERSION"] != "2.10.2" || env["PACKTEST_DIGEST"] != "" {
		t.Fatalf("version env = %#v", env)
	}

	_, err = packTestVersionEnv(2, lookup(map[string]string{"PACKTEST_VERSION": "2.10.2"}))
	if err == nil || !strings.Contains(err.Error(), "exactly one selected pack") {
		t.Fatalf("multi-pack version error = %v", err)
	}

	_, err = packTestVersionEnv(1, lookup(map[string]string{"PACKTEST_DIGEST": "@sha256:abc"}))
	if err == nil || !strings.Contains(err.Error(), "requires PACKTEST_VERSION") {
		t.Fatalf("digest-only error = %v", err)
	}

	_, err = packTestVersionEnv(1, lookup(map[string]string{
		"PACKTEST_VERSION": "2.10.2",
		"PACKTEST_DIGEST":  "sha256:abc",
	}))
	if err == nil || !strings.Contains(err.Error(), "64 lowercase") {
		t.Fatalf("invalid digest error = %v", err)
	}

	_, err = packTestVersionEnv(1, lookup(map[string]string{
		"PACKTEST_VERSION": "2.10.2",
		"PACKTEST_DIGEST":  "@sha256:abc",
	}))
	if err == nil || !strings.Contains(err.Error(), "64 lowercase") {
		t.Fatalf("short digest error = %v", err)
	}
}

func TestResolvedPackTestVersionEnvUsesDeclaredDigests(t *testing.T) {
	current := packtest.Version{
		Version: "2.11.4",
		Digest:  "@sha256:" + strings.Repeat("a", 64),
		Default: true,
	}
	previous := packtest.Version{
		Version: "2.10.2",
		Digest:  "@sha256:" + strings.Repeat("b", 64),
	}
	plan := packtest.PlanRef{Name: "caddy", Versions: []packtest.Version{current, previous}}

	env := resolvedPackTestVersionEnv(plan, nil)
	if env["PACKTEST_VERSION"] != current.Version || env["PACKTEST_DIGEST"] != current.Digest {
		t.Fatalf("default env = %#v", env)
	}

	env = resolvedPackTestVersionEnv(plan, map[string]string{
		"PACKTEST_VERSION": previous.Version,
		"PACKTEST_DIGEST":  "",
	})
	if env["PACKTEST_DIGEST"] != previous.Digest {
		t.Fatalf("declared override env = %#v", env)
	}

	env = resolvedPackTestVersionEnv(plan, map[string]string{
		"PACKTEST_VERSION": "tip",
		"PACKTEST_DIGEST":  "",
	})
	if env["PACKTEST_DIGEST"] != "" {
		t.Fatalf("ad hoc override unexpectedly pinned = %#v", env)
	}
}

func TestRetryPackTestPullSurvivesATransientRegistryFailure(t *testing.T) {
	var log bytes.Buffer
	attempts := 0
	err := retryPackTestPull(context.Background(), 0, &log, func() error {
		attempts++
		if attempts < packTestPullAttempts {
			return errors.New("context deadline exceeded")
		}
		return nil
	})
	if err != nil {
		t.Fatalf("gave up on a transient failure: %v", err)
	}
	if attempts != packTestPullAttempts {
		t.Fatalf("attempts = %d, want %d", attempts, packTestPullAttempts)
	}
	if !strings.Contains(log.String(), "retrying: context deadline exceeded") {
		t.Fatalf("retry went unreported:\n%s", log.String())
	}
}

func TestRetryPackTestPullReportsAPersistentFailure(t *testing.T) {
	attempts := 0
	err := retryPackTestPull(context.Background(), 0, io.Discard, func() error {
		attempts++
		return errors.New("no such image")
	})
	if err == nil || !strings.Contains(err.Error(), "no such image") {
		t.Fatalf("err = %v, want the pull's own failure", err)
	}
	if attempts != packTestPullAttempts {
		t.Fatalf("attempts = %d, want %d", attempts, packTestPullAttempts)
	}
}

func TestRetryPackTestPullStopsWhenTheRunIsCancelled(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	attempts := 0
	err := retryPackTestPull(ctx, time.Hour, io.Discard, func() error {
		attempts++
		cancel()
		return errors.New("context deadline exceeded")
	})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v, want context.Canceled", err)
	}
	if attempts != 1 {
		t.Fatalf("attempts = %d, want 1", attempts)
	}
}

// packTestDockerLog puts a fake docker on PATH that records the Compose project
// and the arguments of every invocation. FAIL_RUN makes the case's own `compose
// run` fail, the way a failing behavior case does.
func packTestDockerLog(t *testing.T, root string) string {
	t.Helper()
	bin := filepath.Join(root, "fake-bin")
	if err := os.Mkdir(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	log := filepath.Join(root, "commands.log")
	script := "#!/bin/sh\n" +
		"printf '%s|%s\\n' \"$COMPOSE_PROJECT_NAME\" \"$*\" >> \"$COMMAND_LOG\"\n" +
		"if [ -n \"$BLOCK_RUN\" ]; then case \" $* \" in *\" run \"*) while :; do :; done ;; esac; fi\n" +
		"if [ -n \"$FAIL_RUN\" ]; then case \" $* \" in *\" run \"*) exit 1 ;; esac; fi\n"
	if err := os.WriteFile(filepath.Join(bin, "docker"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin)
	t.Setenv("COMMAND_LOG", log)
	return log
}

// panicOnWrite stands in for anything that can abandon a case between the run
// and the teardown — here, the first write after a run fails.
type panicOnWrite struct {
	io.Writer
	trigger string
}

func (w panicOnWrite) Write(data []byte) (int, error) {
	if strings.Contains(string(data), w.trigger) {
		panic("writing " + w.trigger)
	}
	return w.Writer.Write(data)
}

// A case owns containers, networks and volumes named after its Compose project,
// so every in-process exit path — including panic unwinding — has to tear that
// project down exactly once, and last.
func TestRunPackTestCaseAlwaysTearsDownItsComposeProject(t *testing.T) {
	const runnerImage = "emisar-runner-tools:abc123456789"
	baseCompose := filepath.Join("dev", "test-packs", "compose.yaml")
	job := packTestJob{
		InvocationID: "run-1",
		Plan: packtest.PlanRef{
			Name:     "postgres",
			Path:     filepath.Join("packs", "postgres", "test", "cases.yaml"),
			Services: []string{"postgres"},
		},
		Case: packtest.CaseRef{ID: "uptime"},
	}
	compose := "compose -f " + baseCompose + " -f " + filepath.Join("packs", "postgres", "test", "compose.yaml") + " "
	up := compose + "up -d --wait postgres"
	run := compose + "run --rm --no-deps --entrypoint /opt/emisar/bin/packtest runner-tools " +
		"--pack postgres --case uptime --reports /tmp/packtest-reports"
	down := compose + "down -v --remove-orphans"

	tests := []struct {
		name         string
		failRun      string
		interruptRun bool
		panicOn      string
		want         []string
		wantErr      string
	}{
		{name: "a passing case tears down once", want: []string{up, run, down}},
		{name: "an interrupted run still tears down", interruptRun: true, want: []string{up, run, down}, wantErr: "docker compose"},
		{
			name:    "a panic tears down while unwinding",
			failRun: "1",
			panicOn: "failure evidence",
			want:    []string{up, run, down},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			root := t.TempDir()
			log := packTestDockerLog(t, root)
			t.Setenv("FAIL_RUN", test.failRun)
			if test.interruptRun {
				t.Setenv("BLOCK_RUN", "1")
			}
			var output bytes.Buffer
			app := New(root, strings.NewReader(""), &output, &output)
			if test.panicOn != "" {
				app.Out = panicOnWrite{Writer: &output, trigger: test.panicOn}
			}
			ctx := t.Context()
			var interrupted <-chan bool
			if test.interruptRun {
				interruptCtx, cancel := context.WithCancel(ctx)
				ctx = interruptCtx
				result := make(chan bool, 1)
				interrupted = result
				go func() {
					deadline := time.NewTimer(time.Second)
					defer deadline.Stop()
					ticker := time.NewTicker(time.Millisecond)
					defer ticker.Stop()
					for {
						select {
						case <-ticker.C:
							data, _ := os.ReadFile(log)
							if strings.Contains(string(data), " run ") {
								cancel()
								result <- true
								return
							}
						case <-deadline.C:
							cancel()
							result <- false
							return
						}
					}
				}()
			}

			var err error
			func() {
				defer func() {
					if recovered := recover(); (recovered != nil) != (test.panicOn != "") {
						t.Errorf("recovered = %v, want a panic: %t", recovered, test.panicOn != "")
					}
				}()
				err = app.runPackTestCase(ctx, baseCompose, runnerImage, job)
			}()
			if interrupted != nil && !<-interrupted {
				t.Fatal("fake docker run did not start before cancellation")
			}
			if test.panicOn == "" {
				if test.wantErr == "" && err != nil {
					t.Fatalf("err = %v", err)
				}
				if test.wantErr != "" && (err == nil || !strings.Contains(err.Error(), test.wantErr)) {
					t.Fatalf("err = %v, want %q", err, test.wantErr)
				}
			}

			data, readErr := os.ReadFile(log)
			if readErr != nil {
				t.Fatal(readErr)
			}
			project := packTestComposeEnv(root, job.InvocationID, runnerImage, job.Plan, job.Case.ID, nil, "")["COMPOSE_PROJECT_NAME"]
			want := make([]string, len(test.want))
			for i, command := range test.want {
				want[i] = project + "|" + command
			}
			got := strings.Split(strings.TrimSpace(string(data)), "\n")
			if !slices.Equal(got, want) {
				t.Fatalf("commands:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
			}
		})
	}
}

func TestWritePackTestFailureReportsIncludesRowAndError(t *testing.T) {
	dir := t.TempDir()
	plan := packtest.PlanRef{
		Name: "caddy",
		Versions: []packtest.Version{{
			Version: "2.11.4",
			Digest:  "@sha256:" + strings.Repeat("a", 64),
			Default: true,
		}},
	}
	if err := writePackTestFailureReports(dir, []packtest.PlanRef{plan}, nil, errors.New("registry throttled")); err != nil {
		t.Fatal(err)
	}
	report, err := os.ReadFile(filepath.Join(dir, "caddy.log"))
	if err != nil {
		t.Fatal(err)
	}
	for _, expected := range []string{
		"Pack: caddy",
		"SUT version: 2.11.4",
		"SUT digest: @sha256:" + strings.Repeat("a", 64),
		"Error: preflight: registry throttled",
	} {
		if !strings.Contains(string(report), expected) {
			t.Fatalf("report missing %q:\n%s", expected, report)
		}
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

func TestWriteSSORealmChangesOnlyPortalRedirect(t *testing.T) {
	source := filepath.Join(t.TempDir(), "realm.json")
	destination := filepath.Join(t.TempDir(), "generated.json")
	fixture := `{"realm":"emisar","clients":[{"clientId":"other","redirectUris":["https://example.com"]},{"clientId":"emisar-portal","redirectUris":["http://localhost:4010/old"]}]}`
	if err := os.WriteFile(source, []byte(fixture), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := writeSSORealm(source, destination, 43210); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(destination)
	if err != nil {
		t.Fatal(err)
	}
	var realm struct {
		Clients []struct {
			ID        string   `json:"clientId"`
			Redirects []string `json:"redirectUris"`
		} `json:"clients"`
	}
	if err := json.Unmarshal(data, &realm); err != nil {
		t.Fatal(err)
	}
	if got := realm.Clients[0].Redirects; !slices.Equal(got, []string{"https://example.com"}) {
		t.Fatalf("other redirects = %v", got)
	}
	if got := realm.Clients[1].Redirects; !slices.Equal(got, []string{"http://localhost:43210/sign_in/sso/callback"}) {
		t.Fatalf("portal redirects = %v", got)
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

func TestScreenshotOutputUsesTheOnlyInProgressTask(t *testing.T) {
	app := testApp(t)
	task := filepath.Join(app.Root, "portal", ".agent", "tasks", "10_in_progress", "task-one")
	if err := os.MkdirAll(task, 0o755); err != nil {
		t.Fatal(err)
	}

	selected, output, err := app.screenshotOutput("", "pricing/mobile")
	if err != nil {
		t.Fatal(err)
	}
	if selected.ID != "task-one" {
		t.Fatalf("selected task = %q", selected.ID)
	}
	want := filepath.Join(task, "screenshots", "pricing", "mobile")
	if output != want {
		t.Fatalf("output = %q, want %q", output, want)
	}
}

func TestScreenshotOutputRequiresAnInProgressTask(t *testing.T) {
	app := testApp(t)

	_, _, err := app.screenshotOutput("", "")
	if err == nil || !strings.Contains(err.Error(), "coop tasks add") || !strings.Contains(err.Error(), "coop tasks claim") {
		t.Fatalf("error = %v", err)
	}
}

func TestScreenshotOutputRequiresTaskSelectionWhenSeveralAreActive(t *testing.T) {
	app := testApp(t)
	for _, path := range []string{
		filepath.Join(app.Root, ".agent", "tasks", "10_in_progress", "root-task"),
		filepath.Join(app.Root, "portal", ".agent", "tasks", "10_in_progress", "portal-task"),
	} {
		if err := os.MkdirAll(path, 0o755); err != nil {
			t.Fatal(err)
		}
	}

	if _, _, err := app.screenshotOutput("", ""); err == nil || !strings.Contains(err.Error(), "--task <id>") {
		t.Fatalf("ambiguous task error = %v", err)
	}
	selected, output, err := app.screenshotOutput("portal-task", "")
	if err != nil {
		t.Fatal(err)
	}
	if selected.ID != "portal-task" || output != filepath.Join(selected.Path, "screenshots") {
		t.Fatalf("selection = %#v, output = %q", selected, output)
	}
}

func TestScreenshotOutputRejectsEscapingGroup(t *testing.T) {
	app := testApp(t)
	if err := os.MkdirAll(filepath.Join(app.Root, ".agent", "tasks", "10_in_progress", "task-one"), 0o755); err != nil {
		t.Fatal(err)
	}

	if _, _, err := app.screenshotOutput("", "../elsewhere"); err == nil || !strings.Contains(err.Error(), "must stay inside") {
		t.Fatalf("escaping group error = %v", err)
	}
}

func TestParseShotRejectsArbitraryOutputDirectory(t *testing.T) {
	_, err := parseShot([]string{"/pricing", "--label", "after", "--out", ".agent/screenshots/pricing"})
	if err == nil || !IsUsage(err) {
		t.Fatalf("parse error = %v", err)
	}
}

func TestParseShotAcceptsTaskOwnedGrouping(t *testing.T) {
	command, err := parseShot([]string{
		"/pricing", "--label", "after", "--task", "task-one", "--group", "pricing/mobile", "--heading", "Pricing",
	})
	if err != nil {
		t.Fatal(err)
	}
	if command.taskID != "task-one" || command.group != "pricing/mobile" || command.options.Path != "/pricing" {
		t.Fatalf("command = %#v", command)
	}
	if command.options.Anchor == nil || command.options.Anchor.Heading != "Pricing" {
		t.Fatalf("anchor = %#v", command.options.Anchor)
	}
}

func TestParseShotKeepsRepeatedClicksInOrder(t *testing.T) {
	command, err := parseShot([]string{
		"/app/acme/runbooks/1/edit", "--label", "open",
		"--click", "#step-0 [data-expand]",
		"--click", "#step-0 [data-combobox-trigger]",
	})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"#step-0 [data-expand]", "#step-0 [data-combobox-trigger]"}
	if !slices.Equal(command.options.Clicks, want) {
		t.Fatalf("clicks = %#v", command.options.Clicks)
	}
}

func TestParseShotUsesEmailOverride(t *testing.T) {
	t.Setenv("EMAIL", "user@example.test")

	command, err := parseShot([]string{"/app/acme/runs", "--label", "after"})
	if err != nil {
		t.Fatal(err)
	}
	if command.options.Email != "user@example.test" {
		t.Fatalf("email = %q", command.options.Email)
	}
}

func TestCaptureConsoleRequiresTaskBeforeStartingBrowser(t *testing.T) {
	app := testApp(t)
	err := app.capture(t.Context(), []string{"console"})
	if err == nil || !strings.Contains(err.Error(), "in-progress task") {
		t.Fatalf("capture error = %v", err)
	}
}

func TestNoArgumentsPrintsGroupedHumanHelpAndSucceeds(t *testing.T) {
	var out bytes.Buffer
	app := New(t.TempDir(), strings.NewReader(""), &out, &bytes.Buffer{})

	if err := app.Run(t.Context(), nil); err != nil {
		t.Fatal(err)
	}
	help := out.String()
	for _, section := range []string{
		"Emisar development",
		"First run:",
		"Fast feedback:",
		"Local development:",
		"Test and verify:",
		"Browser and UI:",
		"Cross-component scenarios:",
		"Action packs:",
		"Production operations:",
		"More help:",
	} {
		if !strings.Contains(help, section) {
			t.Fatalf("help does not contain %q:\n%s", section, help)
		}
	}
	if strings.Contains(help, "a command is required") {
		t.Fatalf("no-argument help still reports an error:\n%s", help)
	}
}

func TestDownStopsTheWorkspaceAndWithAllTheSmokeStack(t *testing.T) {
	tests := []struct {
		name string
		args []string
		want []string
	}{
		{name: "bare down stops only the workspace", args: []string{"down"}, want: []string{"coop|down"}},
		{name: "--all also stops the smoke stack", args: []string{"down", "--all"}, want: []string{"coop|down", "docker|compose down"}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			root := t.TempDir()
			bin := filepath.Join(root, "fake-bin")
			if err := os.Mkdir(bin, 0o755); err != nil {
				t.Fatal(err)
			}
			log := filepath.Join(root, "commands.log")
			t.Setenv("COMMAND_LOG", log)
			t.Setenv("PATH", bin)
			t.Setenv("COOP_BOX", "")
			for _, name := range []string{"coop", "docker"} {
				script := "#!/bin/sh\nprintf '%s|%s|%s\\n' \"$PWD\" '" + name + "' \"$*\" >> \"$COMMAND_LOG\"\n"
				if err := os.WriteFile(filepath.Join(bin, name), []byte(script), 0o755); err != nil {
					t.Fatal(err)
				}
			}
			app := New(root, strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{})

			if err := app.Run(t.Context(), test.args); err != nil {
				t.Fatal(err)
			}
			data, err := os.ReadFile(log)
			if err != nil {
				t.Fatal(err)
			}
			dir, err := filepath.EvalSymlinks(root)
			if err != nil {
				t.Fatal(err)
			}
			want := make([]string, len(test.want))
			for i, command := range test.want {
				want[i] = dir + "|" + command
			}
			got := strings.Split(strings.TrimSpace(string(data)), "\n")
			if !slices.Equal(got, want) {
				t.Fatalf("commands:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
			}
		})
	}
}

func TestDownRejectsUnknownArgumentsAndBoxes(t *testing.T) {
	app := testApp(t)
	for _, args := range [][]string{{"down", "-v"}, {"down", "--all", "extra"}} {
		if err := app.Run(t.Context(), args); !IsUsage(err) {
			t.Fatalf("%v error = %v, want usage", args, err)
		}
	}
	t.Setenv("COOP_BOX", "1")
	for _, args := range [][]string{{"down"}, {"down", "--all"}} {
		if err := app.Run(t.Context(), args); err == nil || !strings.Contains(err.Error(), "on the host") {
			t.Fatalf("%v in-box error = %v", args, err)
		}
	}
}

func TestMainHelpListsEveryPublicCommand(t *testing.T) {
	for _, command := range []string{
		"setup", "up", "down", "serve", "status", "logs", "psql", "seed", "reset", "urls", "doctor", "certs",
		"test", "check", "gate", "browser", "shot", "capture", "e2e",
		"smoke", "pack", "ops", "help",
	} {
		if !strings.Contains(usageText, "\n  "+command+" ") {
			t.Errorf("main help does not list %q", command)
		}
	}
	if !strings.Contains(usageText, "./run bootstrap") {
		t.Error("main help does not list the shell bootstrap")
	}
}

func TestReadToolVersionsAndVersionParsers(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".tool-versions")
	if err := os.WriteFile(path, []byte("# pins\nerlang 29.0.3\nelixir 1.20.2-otp-29\ngolang 1.26.6\nterraform 1.15.8\ntflint 0.64.0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	pins, err := readToolVersions(path)
	if err != nil {
		t.Fatal(err)
	}
	if pins["erlang"] != "29.0.3" || pins["tflint"] != "0.64.0" || len(pins) != 5 {
		t.Fatalf("pins = %#v", pins)
	}
	for _, test := range []struct {
		parse  func(string) string
		input  string
		output string
	}{
		{regexpVersion(goVersionPattern), "go version go1.26.5 darwin/arm64", "1.26.5"},
		{parseElixirVersion, "Erlang/OTP 29\nElixir 1.20.2\n", "1.20.2-otp-29"},
		{regexpVersion(terraformVersionPattern), "Terraform v1.15.8\n", "1.15.8"},
		{regexpVersion(tflintVersionPattern), "TFLint version 0.64.0\n", "0.64.0"},
	} {
		if got := test.parse(test.input); got != test.output {
			t.Errorf("parsed %q as %q, want %q", test.input, got, test.output)
		}
	}
}

func TestHelpPrintsFocusedGateCommands(t *testing.T) {
	var out bytes.Buffer
	app := New(t.TempDir(), strings.NewReader(""), &out, &bytes.Buffer{})

	if err := app.Run(t.Context(), []string{"help", "gate"}); err != nil {
		t.Fatal(err)
	}
	for _, command := range []string{"gate portal", "gate runner", "gate mcp", "gate packs", "gate infra", "gate tooling", "gate review", "gate all"} {
		if !strings.Contains(out.String(), strings.TrimPrefix(command, "gate ")) {
			t.Fatalf("help does not mention %q:\n%s", command, out.String())
		}
	}
}

func TestReviewGateTargetsUseCanonicalOrderAndFallback(t *testing.T) {
	got := reviewGateTargets(ci.Selection{
		Portal: true,
		Runner: true,
		Tools:  true,
		Packs:  true,
	})
	want := []string{"tooling", "runner", "packs", "portal"}
	if !slices.Equal(got, want) {
		t.Fatalf("targets = %v, want %v", got, want)
	}
	if got := reviewGateTargets(ci.Selection{}); !slices.Equal(got, []string{"tooling"}) {
		t.Fatalf("fallback targets = %v, want [tooling]", got)
	}
}

func TestPackTestModeExtractsOneHostileFlag(t *testing.T) {
	args, hostile, err := packTestMode([]string{"postgres", "--shard", "1/2", "--hostile"})
	if err != nil {
		t.Fatal(err)
	}
	if !hostile || !slices.Equal(args, []string{"postgres", "--shard", "1/2"}) {
		t.Fatalf("mode = (%v, %t)", args, hostile)
	}
	if _, _, err := packTestMode([]string{"--hostile", "--hostile"}); !IsUsage(err) {
		t.Fatalf("duplicate hostile error = %v", err)
	}
}

func TestHostilePackTestOverrideLimitsOnlySUTServices(t *testing.T) {
	reports := t.TempDir()
	path, err := writePackTestHostileOverride(reports, packtest.PlanRef{
		Name: "example", Services: []string{"database", "helper"},
	})
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	text := string(data)
	// The pid ceiling is a runaway-fork backstop, not part of the starvation
	// this mode applies — CPU and memory are. Do not lower it back toward a
	// server's thread-pool size: at 512 a stock ClickHouse could not finish
	// booting, and every case failed at setup on a container that never
	// became healthy.
	for _, expected := range []string{"database:", "helper:", "cpus: \"1.0\"", "mem_limit: 1536m", "pids_limit: 4096"} {
		if !strings.Contains(text, expected) {
			t.Fatalf("hostile override lacks %q:\n%s", expected, text)
		}
	}
	if strings.Contains(text, "runner-tools") {
		t.Fatalf("hostile override constrained the action client:\n%s", text)
	}
	args := packTestComposeArgs("base.yaml", "pack.yaml", path)
	if !slices.Equal(args, []string{"compose", "-f", "base.yaml", "-f", "pack.yaml", "-f", path}) {
		t.Fatalf("compose args = %v", args)
	}
}

// The Go gate decides the client-module boundary, so a synthetic root has to
// carry the layout it judges: runner/cmd holding exactly packctl, and no
// mcp/cmd at all.
func writeClientModuleLayout(t *testing.T, root string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(root, "runner", "cmd", "packctl"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "mcp"), 0o755); err != nil {
		t.Fatal(err)
	}
	// The gate also decides attestation parity, which reads both copies of the
	// verifier — identical bytes and identical fixed vectors.
	implementation := "package attest\n"
	vectors := "package attest\n\nconst (\n\tname: \"empty args\"\n\tcertBytes = \"\"\n\tenvelopeBase64URL = \"\"\n)\n"
	for _, module := range []string{"runner", "mcp"} {
		dir := filepath.Join(root, module, "internal", "attest")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "attest.go"), []byte(implementation), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "attest_test.go"), []byte(vectors), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func TestClientModuleBoundaries(t *testing.T) {
	root := t.TempDir()
	writeClientModuleLayout(t, root)
	app := New(root, strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{})

	if err := app.checkClientModuleBoundaries("runner"); err != nil {
		t.Fatalf("the sanctioned layout must pass: %v", err)
	}
	if err := app.checkClientModuleBoundaries("tools"); err != nil {
		t.Fatalf("repo tooling is exempt: %v", err)
	}

	if err := os.MkdirAll(filepath.Join(root, "runner", "cmd", "smuggled"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := app.checkClientModuleBoundaries("runner"); err == nil ||
		!strings.Contains(err.Error(), "exactly packctl") {
		t.Fatalf("a second runner/cmd binary must fail: %v", err)
	}
	if err := os.RemoveAll(filepath.Join(root, "runner", "cmd", "smuggled")); err != nil {
		t.Fatal(err)
	}

	if err := os.MkdirAll(filepath.Join(root, "mcp", "cmd"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := app.checkClientModuleBoundaries("mcp"); err == nil ||
		!strings.Contains(err.Error(), "carries no cmd/") {
		t.Fatalf("an mcp/cmd must fail: %v", err)
	}
}

func TestRunnerGateUsesModuleDirectoryAndCoverage(t *testing.T) {
	root := t.TempDir()
	writeClientModuleLayout(t, root)
	bin := filepath.Join(root, "fake-bin")
	if err := os.Mkdir(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	log := filepath.Join(root, "commands.log")
	t.Setenv("COMMAND_LOG", log)
	t.Setenv("PATH", bin)
	for _, name := range []string{"bash", "gofmt", "go", "git", "shellcheck"} {
		script := "#!/bin/sh\nprintf '%s|%s|%s\\n' \"$PWD\" '" + name + "' \"$*\" >> \"$COMMAND_LOG\"\n"
		path := filepath.Join(bin, name)
		if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	app := New(root, strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{})

	if err := app.Run(t.Context(), []string{"gate", "runner", "--coverage", "coverage.out"}); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	module, err := filepath.EvalSymlinks(filepath.Join(root, "runner"))
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		module + "|gofmt|-l -s .",
		module + "|go|mod verify",
		module + "|go|vet ./...",
		module + "|go|run " + staticcheckVersion + " ./...",
		module + "|go|mod tidy -diff",
		module + "|go|test -race -count=1 -coverprofile=coverage.out ./...",
	}
	// One build per published platform, in order, so a dropped or added target
	// is a visible diff here rather than a silent change in release coverage.
	for range releaseTargets["runner"] {
		want = append(want, module+"|go|build -trimpath -ldflags -s -w -o "+os.DevNull+" .")
	}
	want = append(want,
		filepath.Dir(module)+"|shellcheck|install.sh",
		filepath.Dir(module)+"|bash|-n install.sh",
		filepath.Dir(module)+"|go|run ./tools/cmd/installtest runner",
	)
	got := strings.Split(strings.TrimSpace(string(data)), "\n")
	if !slices.Equal(got, want) {
		t.Fatalf("commands:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}

func TestGoRaceSupported(t *testing.T) {
	tests := []struct {
		name   string
		goos   string
		goarch string
		want   bool
	}{
		{"linux amd64", "linux", "amd64", true},
		{"windows amd64", "windows", "amd64", true},
		{"windows arm64", "windows", "arm64", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := goRaceSupported(tt.goos, tt.goarch); got != tt.want {
				t.Fatalf("goRaceSupported(%q, %q) = %t, want %t", tt.goos, tt.goarch, got, tt.want)
			}
		})
	}
}

func TestMCPGateRejectsDependencyChecksumFile(t *testing.T) {
	root := t.TempDir()
	module := filepath.Join(root, "mcp")
	if err := os.Mkdir(module, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(module, "go.sum"), []byte("unexpected\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	writeClientModuleLayout(t, root)
	bin := filepath.Join(root, "fake-bin")
	if err := os.Mkdir(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin)
	for _, name := range []string{"gofmt", "go"} {
		path := filepath.Join(bin, name)
		if err := os.WriteFile(path, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	app := New(root, strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{})

	err := app.Run(t.Context(), []string{"gate", "mcp"})
	if err == nil || !strings.Contains(err.Error(), "stdlib-only") {
		t.Fatalf("error = %v", err)
	}
}
