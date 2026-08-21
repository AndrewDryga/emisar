//go:build !windows

package browser

import (
	"bufio"
	"context"
	"encoding/base64"
	"errors"
	"flag"
	"fmt"
	"image/png"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/chromedp/chromedp"
)

// TestMain lets this test binary stand in for the devtool CLI as a daemon target: Manager.Start
// re-execs its binary with __browser-daemon argv, and only devtool implements that command. The
// intercept mirrors devtool's own flag surface, which is what makes a real spawned-daemon test
// possible without building devtool first.
func TestMain(m *testing.M) {
	if len(os.Args) > 1 && os.Args[1] == "__browser-daemon" {
		flags := flag.NewFlagSet("__browser-daemon", flag.ExitOnError)
		config := Config{Out: os.Stdout, Err: os.Stderr}
		flags.StringVar(&config.State, "state", "", "")
		flags.StringVar(&config.Profile, "profile", "", "")
		flags.StringVar(&config.Marker, "marker", "", "")
		flags.StringVar(&config.SPKI, "spki", "", "")
		flags.BoolVar(&config.InBox, "box", false, "")
		if err := flags.Parse(os.Args[2:]); err != nil {
			os.Exit(2)
		}
		if err := RunDaemon(context.Background(), config); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		os.Exit(0)
	}
	os.Exit(m.Run())
}

// Chrome's zygote needs user namespaces. A coop box lacks them, and so does a
// GitHub runner — without the container flags it aborts with "No usable
// sandbox!" before the debugging port opens. chromeArgs deliberately keeps the
// sandbox on for a host config, so the sandbox-less environments declare
// themselves here rather than weakening that default.
func testInBox() bool {
	return os.Getenv("COOP_BOX") == "1" || os.Getenv("CI") != ""
}

func TestChromeArgsKeepHostSandboxAndScopeTLSException(t *testing.T) {
	spki := base64.StdEncoding.EncodeToString(make([]byte, 32))
	host := chromeArgs(Config{Profile: "/tmp/profile", SPKI: spki})
	if slices.Contains(host, "--no-sandbox") {
		t.Fatal("host browser disables the Chrome sandbox")
	}
	if !slices.Contains(host, "--ignore-certificate-errors-spki-list="+spki) {
		t.Fatalf("host args do not contain the exact SPKI: %v", host)
	}
	box := chromeArgs(Config{Profile: "/tmp/profile", SPKI: spki, InBox: true})
	if !slices.Contains(box, "--no-sandbox") || !slices.Contains(box, "--disable-dev-shm-usage") {
		t.Fatalf("box args lack container flags: %v", box)
	}
}

func TestWriteStateIsAtomicAndPrivate(t *testing.T) {
	path := filepath.Join(t.TempDir(), "browser.json")
	want := State{DaemonPID: 1, BrowserPID: 2, WSEndpoint: "ws://127.0.0.1:1/devtools/browser/test", TLSSPKI: "hash"}
	if err := writeState(path, want); err != nil {
		t.Fatal(err)
	}
	got, err := readState(path)
	if err != nil || got != want {
		t.Fatalf("state = %+v, err=%v", got, err)
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("state mode = %v", info.Mode().Perm())
	}
}

func TestEndpointAliveRejectsNonLoopbackEndpoint(t *testing.T) {
	if endpointAlive("ws://example.com:9222/devtools/browser/test") {
		t.Fatal("accepted a non-loopback browser endpoint")
	}
}

func TestReadyAnchorsAndTwoScaleScreenshot(t *testing.T) {
	if _, err := ResolveChrome(); err != nil {
		t.Skip(err)
	}
	releaseSlow := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path == "/slow" {
			select {
			case <-request.Context().Done():
			case <-releaseSlow:
			}
			return
		}
		writer.Header().Set("Content-Type", "text/html")
		_, _ = writer.Write([]byte(`<!doctype html><html><body><main data-phx-main><h2><span>Target</span></h2></main><script>setTimeout(()=>{document.querySelector('main').classList.add('phx-connected');const img=document.createElement('img');img.src='/slow';img.style='width:20px;height:20px';document.body.append(img)},100)</script><style>h2{width:200px;height:80px;margin:0}</style></body></html>`))
	}))
	defer server.Close()
	defer close(releaseSlow)
	manager := New(Config{InBox: testInBox()})
	session, err := manager.isolatedSessionWithOptions(context.Background(), server.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	if err := session.Viewport(800, 600, 1, false); err != nil {
		t.Fatal(err)
	}
	if err := session.Navigate("/"); err != nil {
		t.Fatal(err)
	}
	if err := session.MarkAnchor(Anchor{Heading: "Target"}, "data-shot-target"); err != nil {
		t.Fatal(err)
	}
	started := time.Now()
	if err := session.Ready(4*time.Second, `[data-shot-target="1"]`); err != nil {
		t.Fatal(err)
	}
	if elapsed := time.Since(started); elapsed > 3*time.Second {
		t.Fatalf("asset readiness was not bounded: %v", elapsed)
	}
	path := filepath.Join(t.TempDir(), "crop.png")
	if err := session.ElementScreenshot(`[data-shot-target="1"]`, path, 2); err != nil {
		t.Fatal(err)
	}
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	image, err := png.Decode(file)
	if err != nil {
		t.Fatal(err)
	}
	if image.Bounds().Dx() < 120 || image.Bounds().Dy() < 50 {
		t.Fatalf("2x crop dimensions = %v", image.Bounds())
	}
}

func TestRGBHex(t *testing.T) {
	if got := rgbHex("rgba(9, 10, 255, 1)"); got != "#090aff" {
		t.Fatalf("rgbHex = %s", got)
	}
	if !strings.HasPrefix(rgbHex("transparent"), "#") {
		t.Fatal("fallback is not a color")
	}
}

func TestSelectShotsIncludesKeycloakGuide(t *testing.T) {
	shots, runLoop, err := selectShots([]string{"keycloak-client-secret"})
	if err != nil {
		t.Fatal(err)
	}
	if runLoop {
		t.Fatal("Keycloak shot selected the approval loop")
	}
	if len(shots) != 1 || shots[0].Name != "keycloak-client-secret" || !shots[0].Keycloak {
		t.Fatalf("shots = %+v", shots)
	}
}

func TestPaddleURLRequiresExactPaddleHost(t *testing.T) {
	for _, raw := range []string{"https://checkout.paddle.com/pay", "https://paddle.com/"} {
		if !isPaddleURL(raw) {
			t.Fatalf("rejected Paddle URL %s", raw)
		}
	}
	for _, raw := range []string{"https://evilpaddle.com/", "https://paddle.com.example/", "not a URL"} {
		if isPaddleURL(raw) {
			t.Fatalf("accepted non-Paddle URL %s", raw)
		}
	}
}

func TestRemoteSessionCanCreateIsolatedContext(t *testing.T) {
	if _, err := ResolveChrome(); err != nil {
		t.Skip(err)
	}
	root := t.TempDir()
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path == "/set" {
			http.SetCookie(writer, &http.Cookie{Name: "auth", Value: "yes", Path: "/"})
		}
		_, _ = writer.Write([]byte("<!doctype html><title>fixture</title>"))
	}))
	t.Cleanup(server.Close)
	config := Config{
		State: filepath.Join(root, "state.json"), Profile: filepath.Join(root, "profile"),
		Marker: filepath.Join(root, "profile", "marker"), Log: filepath.Join(root, "browser.log"),
		SPKI: base64.StdEncoding.EncodeToString(make([]byte, 32)), Out: io.Discard, Err: io.Discard,
		InBox: testInBox(),
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- RunDaemon(ctx, config) }()
	t.Cleanup(func() {
		cancel()
		select {
		case err := <-done:
			if err != nil {
				t.Errorf("browser daemon: %v", err)
			}
		case <-time.After(5 * time.Second):
			t.Error("browser daemon did not stop")
		}
	})
	manager := New(config)
	// Same cold-start race as the isolated session: a shared runner needs room.
	startBudget := 10 * time.Second
	if testInBox() {
		startBudget = 90 * time.Second
	}
	deadline := time.Now().Add(startBudget)
	for {
		if _, err := manager.State(); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("browser daemon did not publish live state")
		}
		time.Sleep(100 * time.Millisecond)
	}
	persistent, err := manager.Session(context.Background(), server.URL, false)
	if err != nil {
		t.Fatal(err)
	}
	// Deferred as well as closed explicitly below: t.Fatal runs deferred calls and then Goexits, so
	// a bare Close() after it is never reached and the browser is orphaned onto the container's
	// init, where it holds a coop box open for the whole descendant drain. Close is idempotent.
	defer persistent.Close()
	if err := persistent.Navigate("/set"); err != nil {
		t.Fatal(err)
	}
	// Closed here, before the isolated session opens, so the cookie assertion below still tests a
	// profile the persistent session has finished writing.
	persistent.Close()

	session, err := manager.Session(context.Background(), server.URL, true)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	if err := session.Navigate("/"); err != nil {
		t.Fatal(err)
	}
	var cookies string
	if err := chromedp.Run(session.Context, chromedp.Evaluate("document.cookie", &cookies)); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(cookies, "auth=yes") {
		t.Fatal("isolated session inherited the persistent profile cookie")
	}
	session.Close()
}

// countProcessesMentioning counts live processes whose cmdline contains needle. /proc scan, so
// box/CI (linux) only — exactly where the orphan class bites.
func countProcessesMentioning(t *testing.T, needle string) int {
	t.Helper()
	matches, err := filepath.Glob("/proc/[0-9]*/cmdline")
	if err != nil {
		t.Fatal(err)
	}
	count := 0
	for _, path := range matches {
		data, readErr := os.ReadFile(path)
		if readErr == nil && strings.Contains(string(data), needle) {
			count++
		}
	}
	return count
}

// countIsolatedChromium counts live processes whose cmdline names an isolated-session profile.
func countIsolatedChromium(t *testing.T) int {
	t.Helper()
	return countProcessesMentioning(t, "emisar-browser-isolated")
}

// The lifeline is the only mechanism that survives the owner dying without running any Go code.
// Before it existed this exact shape leaked: an isolated session outlived its owner's SIGKILL,
// because Pdeathsig applies to the immediate child only and Chromium forks the real browser —
// and the orphan then held a coop box open for its whole descendant drain, un-completing the
// finished task. Reproduce the shape: launch a session in a child process, SIGKILL the child,
// and require the whole browser tree to be gone. The stale profile directory is expected — no
// code survives to remove it; only the processes hold a box open.
func TestIsolatedSessionDiesWithSIGKILLedOwner(t *testing.T) {
	if os.Getenv("BROWSER_LIFELINE_CHILD") == "1" {
		manager := New(Config{
			SPKI: base64.StdEncoding.EncodeToString(make([]byte, 32)),
			Out:  io.Discard, Err: io.Discard, InBox: testInBox(),
		})
		session, err := manager.isolatedSessionWithOptions(context.Background(), "http://127.0.0.1:1")
		if err != nil {
			fmt.Println("LAUNCH_FAILED:", err)
			os.Exit(1)
		}
		defer session.Close() // never reached; the parent SIGKILLs us — that is the point
		fmt.Println("READY")
		time.Sleep(60 * time.Second)
		return
	}
	if !testInBox() {
		t.Skip("SIGKILL-orphan semantics are exercised in the box (linux /proc + bundled chromium)")
	}
	baseline := countIsolatedChromium(t)
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	child := exec.Command(self, "-test.run", "^TestIsolatedSessionDiesWithSIGKILLedOwner$", "-test.v")
	child.Env = append(os.Environ(), "BROWSER_LIFELINE_CHILD=1")
	stdout, err := child.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	child.Stderr = io.Discard
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = child.Process.Kill(); _, _ = child.Process.Wait() }()
	ready := make(chan string, 1)
	go func() {
		scanner := bufio.NewScanner(stdout)
		for scanner.Scan() {
			line := scanner.Text()
			if line == "READY" || strings.HasPrefix(line, "LAUNCH_FAILED") {
				ready <- line
				return
			}
		}
		ready <- "EOF"
	}()
	select {
	case line := <-ready:
		if line != "READY" {
			t.Fatalf("child session never became ready: %s", line)
		}
	case <-time.After(120 * time.Second):
		t.Fatal("child session did not start within its cold-start budget")
	}
	if live := countIsolatedChromium(t); live <= baseline {
		t.Fatalf("expected a live isolated browser before the kill (baseline %d, live %d)", baseline, live)
	}
	if err := child.Process.Kill(); err != nil { // SIGKILL: no defers, no Cancel hooks, no Go code
		t.Fatal(err)
	}
	_, _ = child.Process.Wait()
	deadline := time.Now().Add(15 * time.Second)
	for {
		if live := countIsolatedChromium(t); live <= baseline {
			return // the kernel-side lifeline reaped the tree
		}
		if time.Now().After(deadline) {
			t.Fatalf("isolated browser tree survived its owner's SIGKILL (baseline %d, live %d)", baseline, countIsolatedChromium(t))
		}
		time.Sleep(500 * time.Millisecond)
	}
}

// The daemon's lifeline is what makes a boxed daemon die with the command that started it. It is
// deliberately setsid'd so a workstation keeps a warm browser across runs; in an ephemeral box that
// same detachment left the daemon holding the box open for its whole descendant drain, and the
// handoff then un-completed the finished task and re-ran it — three times in one session.
//
// This exercises the mechanism in-process so it runs everywhere, workstations included; the full
// spawned-daemon shape is TestBoxedDaemonDiesWithItsStarter, which needs a box. What matters here
// is that closing the write end cancels the daemon's context, and that a daemon handed NO lifeline
// (a workstation) is never cancelled.
func TestDaemonLifelineCancelsOnStarterExit(t *testing.T) {
	keep, child, err := newLifeline()
	if err != nil {
		t.Fatal(err)
	}
	defer child.Close()
	t.Setenv(daemonLifelineEnv, strconv.Itoa(int(child.Fd())))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	watchLifeline(cancel)
	select {
	case <-ctx.Done():
		t.Fatal("daemon was cancelled while its starter was still alive")
	case <-time.After(300 * time.Millisecond):
	}
	_ = keep.Close() // the starter exits: the kernel closes its end
	select {
	case <-ctx.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("daemon was not cancelled after its starter closed the lifeline")
	}
}

// A workstation daemon inherits nothing and must outlive its starter, so warm-browser reuse keeps
// working. Never probe a bare fd number for this: RunDaemon also runs in-process, where fd 3 is
// whatever that process happens to have open.
func TestDaemonWithoutLifelineIsNeverCancelled(t *testing.T) {
	t.Setenv(daemonLifelineEnv, "")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	watchLifeline(cancel)
	select {
	case <-ctx.Done():
		t.Fatal("daemon with no lifeline was cancelled")
	case <-time.After(500 * time.Millisecond):
	}
}

// The daemon lifeline's write end must stay reachable for the whole process, not just while some
// Manager is: `./run shot` drops its last Manager reference once the session is open, and with the
// write end held on the Manager the os.File finalizer closed it mid-command — the daemon's watcher
// read EOF and SIGKILLed the browser under the running command. holdDaemonLifeline parks it in a
// package-level GC root instead; this pins that ownership contract by dropping every local
// reference, forcing collection and finalizers, and requiring the read end to stay EOF-free.
func TestHeldDaemonLifelineSurvivesGC(t *testing.T) {
	keep, child, err := newLifeline()
	if err != nil {
		t.Fatal(err)
	}
	defer child.Close()
	t.Cleanup(func() { holdDaemonLifeline(nil) })
	holdDaemonLifeline(keep)
	keep = nil
	_ = keep
	for range 3 {
		runtime.GC()
	}
	time.Sleep(100 * time.Millisecond) // room for any wrongly finalizer-driven close to land
	if err := child.SetReadDeadline(time.Now().Add(200 * time.Millisecond)); err != nil {
		t.Fatal(err)
	}
	if _, err := child.Read(make([]byte, 1)); !errors.Is(err, os.ErrDeadlineExceeded) {
		t.Fatalf("lifeline write end did not stay open: read err = %v", err)
	}
}

// The bug this pins: with the daemon lifeline's write end stored on the Manager, the Manager
// going unreachable mid-command let GC finalize the os.File — the boxed daemon's watcher read
// EOF, SIGKILLed the browser group, and every in-box `./run shot` died ~1.5s in with "context
// canceled". Reproduce the shape with a real spawned daemon: start it, drop the Manager, force
// collection, and require the daemon to stay up and be reusable by a fresh Manager — exactly
// what a second `./run shot` in the same box does.
func TestBoxedDaemonSurvivesManagerCollection(t *testing.T) {
	if !testInBox() {
		t.Skip("spawned-daemon lifetime is exercised in the box (linux + bundled chromium)")
	}
	if _, err := ResolveChrome(); err != nil {
		t.Skip(err)
	}
	root := t.TempDir()
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	config := Config{
		State: filepath.Join(root, "state.json"), Profile: filepath.Join(root, "profile"),
		Marker: filepath.Join(root, "profile", "marker"), Log: filepath.Join(root, "browser.log"),
		SPKI: base64.StdEncoding.EncodeToString(make([]byte, 32)), Out: io.Discard, Err: io.Discard,
		InBox: true,
	}
	// Closing the held write end reaps the daemon and its browser tree at test end, so nothing
	// lingers to hold the box open past the test binary.
	t.Cleanup(func() { holdDaemonLifeline(nil) })
	state := func() State {
		manager := New(config)
		started, startErr := manager.Start(context.Background(), self)
		if startErr == nil {
			return started
		}
		// Start's own wait is 10s; a cold chromium start on a shared runner can outrun it while
		// the daemon it already spawned comes up. Keep waiting on the published state instead.
		deadline := time.Now().Add(90 * time.Second)
		for {
			if started, stateErr := manager.State(); stateErr == nil {
				return started
			}
			if time.Now().After(deadline) {
				t.Fatalf("boxed daemon did not come up: %v", startErr)
			}
			time.Sleep(200 * time.Millisecond)
		}
	}()
	// The Manager is unreachable now — the bug's exact shape. Force collection and give a wrongly
	// finalizer-closed lifeline time to kill the daemon, then require it still serves.
	for range 3 {
		runtime.GC()
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if !endpointAlive(state.WSEndpoint) {
			t.Fatal("boxed daemon died once its Manager was collected")
		}
		time.Sleep(300 * time.Millisecond)
	}
	if _, err := New(config).State(); err != nil {
		t.Fatalf("a fresh Manager cannot reuse the daemon: %v", err)
	}
}

// The daemon lifeline end to end: Start hands a boxed daemon fd 3 plus the env var, and the daemon
// — setsid'd, so no signal reaches it through the starter — must still die with the process that
// started it. Reproduce the burn shape: a child process starts a real daemon, the child is
// SIGKILLed, and the daemon and its whole chromium tree must be gone; nothing may remain to hold a
// coop box open for its descendant drain.
func TestBoxedDaemonDiesWithItsStarter(t *testing.T) {
	if os.Getenv("BROWSER_DAEMON_STARTER") == "1" {
		root := os.Getenv("BROWSER_DAEMON_ROOT")
		self, err := os.Executable()
		if err != nil {
			fmt.Println("START_FAILED:", err)
			os.Exit(1)
		}
		manager := New(Config{
			State: filepath.Join(root, "state.json"), Profile: filepath.Join(root, "profile"),
			Marker: filepath.Join(root, "profile", "marker"), Log: filepath.Join(root, "browser.log"),
			SPKI:  base64.StdEncoding.EncodeToString(make([]byte, 32)),
			InBox: true,
		})
		if _, err := manager.Start(context.Background(), self); err != nil {
			// Start's own wait is 10s; a cold chromium start on a shared runner can outrun it while
			// the daemon it already spawned comes up. Keep waiting on the published state instead.
			deadline := time.Now().Add(90 * time.Second)
			for {
				if _, stateErr := manager.State(); stateErr == nil {
					break
				}
				if time.Now().After(deadline) {
					fmt.Println("START_FAILED:", err)
					os.Exit(1)
				}
				time.Sleep(200 * time.Millisecond)
			}
		}
		fmt.Println("READY")
		time.Sleep(120 * time.Second)
		return
	}
	if !testInBox() {
		t.Skip("spawned-daemon lifetime is exercised in the box (linux /proc + bundled chromium)")
	}
	root := t.TempDir()
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	child := exec.Command(self, "-test.run", "^TestBoxedDaemonDiesWithItsStarter$", "-test.v")
	child.Env = append(os.Environ(), "BROWSER_DAEMON_STARTER=1", "BROWSER_DAEMON_ROOT="+root)
	stdout, err := child.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	child.Stderr = io.Discard
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = child.Process.Kill(); _, _ = child.Process.Wait() }()
	ready := make(chan string, 1)
	go func() {
		scanner := bufio.NewScanner(stdout)
		for scanner.Scan() {
			line := scanner.Text()
			if line == "READY" || strings.HasPrefix(line, "START_FAILED") {
				ready <- line
				return
			}
		}
		ready <- "EOF"
	}()
	select {
	case line := <-ready:
		if line != "READY" {
			t.Fatalf("child starter never brought a daemon up: %s", line)
		}
	case <-time.After(120 * time.Second):
		t.Fatal("child starter did not bring a daemon up within its cold-start budget")
	}
	// The daemon's argv and chromium's --user-data-dir both name root, so this counts the daemon
	// plus its browser tree and nothing else.
	if live := countProcessesMentioning(t, root); live < 2 {
		t.Fatalf("expected a live daemon and browser before the kill, saw %d", live)
	}
	if err := child.Process.Kill(); err != nil { // SIGKILL: no defers, no Cancel hooks, no Go code
		t.Fatal(err)
	}
	_, _ = child.Process.Wait()
	deadline := time.Now().Add(15 * time.Second)
	for {
		if live := countProcessesMentioning(t, root); live == 0 {
			return // the lifeline cancelled the daemon, and its Cancel hook group-killed the browser
		}
		if time.Now().After(deadline) {
			t.Fatalf("daemon or browser survived its starter's SIGKILL (%d live)", countProcessesMentioning(t, root))
		}
		time.Sleep(500 * time.Millisecond)
	}
}
