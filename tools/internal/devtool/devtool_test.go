package devtool

import (
	"bytes"
	"context"
	"encoding/json"
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

func TestPackTestComposeProjectIsStableAndPackSpecific(t *testing.T) {
	first := packTestComposeProject("/tmp/a", "postgres")
	if first != packTestComposeProject("/tmp/a", "postgres") ||
		first == packTestComposeProject("/tmp/b", "postgres") ||
		first == packTestComposeProject("/tmp/a", "mysql") {
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
		module + "|go|mod tidy",
		module + "|git|diff --exit-code -- go.mod go.sum",
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
