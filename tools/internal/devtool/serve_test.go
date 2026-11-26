package devtool

import (
	"bytes"
	"encoding/json"
	"fmt"
	"maps"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// serveWorkspace is a box holding exactly the declared Coop services, with the
// runtime, cache, and CA files `up` touches pointed at temporary directories —
// so a case runs the real serve routes without a workspace behind them.
func serveWorkspace(t *testing.T, urls map[workspaceDependency]string) *App {
	t.Helper()
	app := boxWorkspace(t, urls)
	t.Setenv("COOP_FORWARD", "")
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	if urls[needKeycloak] == "" {
		return app
	}
	if err := os.MkdirAll(app.Certs, 0o700); err != nil {
		t.Fatal(err)
	}
	// makeCABundle only concatenates this onto the system bundle; no route under
	// test parses it.
	ca := "-----BEGIN CERTIFICATE-----\ndevelopment\n-----END CERTIFICATE-----\n"
	if err := os.WriteFile(filepath.Join(app.Certs, "ca.crt"), []byte(ca), 0o600); err != nil {
		t.Fatal(err)
	}
	return app
}

// listen holds a port for the duration of the test, standing in for a process
// that already owns it.
func listen(t *testing.T, port int) net.Listener {
	t.Helper()
	listener, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	return listener
}

func freePort(t *testing.T) int {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	return port
}

// recordLaunch replaces the re-exec with a recorder that opens the port the
// real child would open, so the parent's wait resolves without starting
// Phoenix. The count it returns is what proves a refusal spawned nothing.
func recordLaunch(t *testing.T, app *App, port int) *int {
	t.Helper()
	launches := 0
	app.launchDetachedServe = func(logFile *os.File) error {
		if logFile == nil {
			t.Fatal("detached launch received no log file")
		}
		launches++
		listen(t, port)
		return nil
	}
	return &launches
}

// A detached parent used to validate only the Portal and then wait three
// minutes on a child that could not start, reporting the port instead of the
// service. It now refuses exactly what the foreground child requires.
func TestServeDetachedRequiresWhatTheForegroundChildDoes(t *testing.T) {
	port := freePort(t)
	portal := fmt.Sprintf("http://127.0.0.1:%d", port)
	complete := map[workspaceDependency]string{
		needPortal:   portal,
		needMetrics:  "http://127.0.0.1:28617",
		needDatabase: "postgres://postgres:postgres@db:5432/emisar_dev",
		needKeycloak: "https://localhost:30344",
	}
	for _, testCase := range []struct {
		name string
		// absent is the service Coop did not publish, if any.
		absent    workspaceDependency
		present   bool
		wantError string
	}{
		{name: "a complete workspace launches the child and reports the log", present: true},
		{name: "no Postgres refuses by name", absent: needDatabase, wantError: "this command needs Postgres"},
		{name: "no Keycloak still launches the ordinary preview", absent: needKeycloak},
		{name: "unpublished Metrics uses its local listener", absent: needMetrics},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			urls := maps.Clone(complete)
			if !testCase.present {
				delete(urls, testCase.absent)
			}
			app := serveWorkspace(t, urls)
			launches := recordLaunch(t, app, port)
			err := app.Run(t.Context(), []string{"serve", "--detach"})
			if testCase.wantError != "" {
				if err == nil || !strings.Contains(err.Error(), testCase.wantError) {
					t.Fatalf("serve --detach error = %v, want one containing %q", err, testCase.wantError)
				}
				// The whole point: nothing was spawned, so nothing had to be
				// waited for or cleaned up.
				if *launches != 0 {
					t.Fatalf("refused startup still launched %d child process(es)", *launches)
				}
				return
			}
			if err != nil {
				t.Fatalf("serve --detach = %v", err)
			}
			if *launches != 1 {
				t.Fatalf("launched %d child processes, want 1", *launches)
			}
			out := app.Out.(*bytes.Buffer).String()
			if !strings.Contains(out, "serving at "+portal) || !strings.Contains(out, "serve.log") {
				t.Fatalf("output = %q", out)
			}
		})
	}
}

// A workspace that holds the Portal alone can still answer for a server that is
// already up: only a new launch needs the whole set.
func TestServeReportsAnAlreadyRunningServerWithoutEveryDependency(t *testing.T) {
	port := freePort(t)
	portal := fmt.Sprintf("http://127.0.0.1:%d", port)
	app := serveWorkspace(t, map[workspaceDependency]string{needPortal: portal})
	launches := recordLaunch(t, app, port)
	listen(t, port)

	if err := app.Run(t.Context(), []string{"serve", "--detach"}); err != nil {
		t.Fatalf("serve --detach = %v", err)
	}
	if err := app.Run(t.Context(), []string{"serve", "--status"}); err != nil {
		t.Fatalf("serve --status = %v", err)
	}
	if *launches != 0 {
		t.Fatalf("an already-serving port still launched %d child process(es)", *launches)
	}
	out := app.Out.(*bytes.Buffer).String()
	if !strings.Contains(out, "already serving at "+portal) || !strings.Contains(out, "serving at "+portal+" (") {
		t.Fatalf("output = %q", out)
	}
}

// In a published box Phoenix listens on 4000 behind a proxy from the public
// port, and serve names its lock after the listener. --status and --stop used
// to look the lock up under the public port, so they never found the owner.
func TestServeStatusFindsTheBoxOwnerBehindAPublishedPort(t *testing.T) {
	port := freePort(t)
	if port == 4000 {
		t.Skip("the free port is the box listener itself")
	}
	portal := fmt.Sprintf("http://127.0.0.1:%d", port)
	app := serveWorkspace(t, map[workspaceDependency]string{needPortal: portal})
	listen(t, port)
	dir, err := app.serveRuntimeDir()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "serve-4000.lock"), []byte("pid 4321"), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := app.Run(t.Context(), []string{"serve", "--status"}); err != nil {
		t.Fatalf("serve --status = %v", err)
	}
	if out := app.Out.(*bytes.Buffer).String(); !strings.Contains(out, "serving at "+portal+" (pid 4321,") {
		t.Fatalf("output = %q", out)
	}
}

// The dev Keycloak listens on loopback, which the portal's IdP address guard
// refuses unless it is listed, so serve must name it or no SSO ceremony starts.
func TestDevSSOAllowedIDPHostsNamesTheWorkspaceKeycloak(t *testing.T) {
	for keycloakURL, want := range map[string]string{
		"https://localhost:30344": "localhost:30344",
		"":                        "",
	} {
		if got := devSSOAllowedIDPHosts(keycloakURL); got != want {
			t.Errorf("devSSOAllowedIDPHosts(%q) = %q, want %q", keycloakURL, got, want)
		}
	}
}

// hostServeWorkspace is the host side: a coop stand-in that answers `fork ls
// --json` with portal as this checkout's portal URL and records every other call.
func hostServeWorkspace(t *testing.T, portal string) (*App, string) {
	t.Helper()
	app := testApp(t)
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
	workspaceJSON, err := json.Marshal(map[string]any{"workspaces": []any{map[string]any{
		"path":  app.Root,
		"serve": map[string]string{"4000": portal},
	}}})
	if err != nil {
		t.Fatal(err)
	}
	bin := t.TempDir()
	calls := filepath.Join(bin, "calls")
	script := fmt.Sprintf("#!/bin/sh\nif [ \"$*\" = 'fork ls --json' ]; then printf '%%s\\n' '%s'; exit 0; fi\necho \"$*\" >> %q\nexit 99\n", workspaceJSON, calls)
	if err := os.WriteFile(filepath.Join(bin, "coop"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	return app, calls
}

// An open Coop box publishes the checkout's portal URL, so on the host the port
// answers while nothing serves. serve used to run coop up first, which waits for
// as long as that box runs, and only then find the port taken.
func TestHostServeRefusesAPortalABoxPublishesBeforeStartingServices(t *testing.T) {
	port := freePort(t)
	portal := fmt.Sprintf("http://127.0.0.1:%d", port)
	listen(t, port)
	for _, args := range [][]string{{"serve"}, {"serve", "--detach"}} {
		app, calls := hostServeWorkspace(t, portal)
		err := app.Run(t.Context(), args)
		if err == nil || !strings.Contains(err.Error(), "Coop box open in this checkout") {
			t.Fatalf("%v with the portal taken = %v, want the box refusal", args, err)
		}
		if called, _ := os.ReadFile(calls); len(called) != 0 {
			t.Fatalf("%v refused only after calling coop: %s", args, called)
		}
	}
}

// A port that a ./run serve holds is that command's own answer to give, not a box.
func TestHostServeLeavesAPortalItsOwnServeHolds(t *testing.T) {
	port := freePort(t)
	portal := fmt.Sprintf("http://127.0.0.1:%d", port)
	listen(t, port)
	app, _ := hostServeWorkspace(t, portal)
	lock, err := app.serveLock(port, portal)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = unlockFile(lock); _ = lock.Close() })
	if err := app.refuseHostPortalTaken(t.Context()); err != nil {
		t.Fatalf("a portal its own serve holds = %v", err)
	}
	if pid, err := app.servePID(port); err != nil || pid != os.Getpid() {
		t.Fatalf("the check rewrote the owner's lock: pid %d, %v", pid, err)
	}
}
