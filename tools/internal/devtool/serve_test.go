package devtool

import (
	"bytes"
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
		{name: "no Keycloak refuses by name", absent: needKeycloak, wantError: "this command needs Keycloak"},
		{name: "no Metrics refuses by name", absent: needMetrics, wantError: "this command needs Metrics"},
		{name: "no Portal refuses by name", absent: needPortal, wantError: "this command needs Portal"},
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
