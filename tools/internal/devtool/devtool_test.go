package devtool

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

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

func TestMainHelpListsEveryPublicCommand(t *testing.T) {
	for _, command := range []string{
		"setup", "up", "down", "serve", "seed", "reset", "urls", "doctor", "certs",
		"test", "check", "gate", "browser", "shot", "capture", "e2e",
		"smoke", "pack", "ops", "help",
	} {
		if !strings.Contains(usageText, "\n  "+command+" ") {
			t.Errorf("main help does not list %q", command)
		}
	}
}

func TestHelpPrintsFocusedGateCommands(t *testing.T) {
	var out bytes.Buffer
	app := New(t.TempDir(), strings.NewReader(""), &out, &bytes.Buffer{})

	if err := app.Run(t.Context(), []string{"help", "gate"}); err != nil {
		t.Fatal(err)
	}
	for _, command := range []string{"gate portal", "gate runner", "gate mcp", "gate packs", "gate infra", "gate tooling", "gate all"} {
		if !strings.Contains(out.String(), strings.TrimPrefix(command, "gate ")) {
			t.Fatalf("help does not mention %q:\n%s", command, out.String())
		}
	}
}

func TestRunnerGateUsesModuleDirectoryAndCoverage(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "runner"), 0o755); err != nil {
		t.Fatal(err)
	}
	bin := filepath.Join(root, "fake-bin")
	if err := os.Mkdir(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	log := filepath.Join(root, "commands.log")
	t.Setenv("COMMAND_LOG", log)
	t.Setenv("PATH", bin)
	for _, name := range []string{"gofmt", "go", "git"} {
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
	got := strings.Split(strings.TrimSpace(string(data)), "\n")
	if !slices.Equal(got, want) {
		t.Fatalf("commands:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
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
