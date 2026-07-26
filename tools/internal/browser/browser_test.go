package browser

import (
	"context"
	"encoding/base64"
	"image/png"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/chromedp/chromedp"
)

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
	if err := persistent.Navigate("/set"); err != nil {
		t.Fatal(err)
	}
	persistent.Close()

	session, err := manager.Session(context.Background(), server.URL, true)
	if err != nil {
		t.Fatal(err)
	}
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
