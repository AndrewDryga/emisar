package installtest

import (
	"encoding/pem"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

func TestRunnerChecksHaveNinePortableAndThreePrivilegedCases(t *testing.T) {
	var portable []string
	var privileged []string
	for _, check := range runnerChecks() {
		if check.requiresRoot {
			privileged = append(privileged, check.name)
			continue
		}
		portable = append(portable, check.name)
	}
	if len(portable) != 9 {
		t.Fatalf("portable checks = %v, want nine", portable)
	}
	wantPrivileged := []string{
		"enrollment state transitions",
		"binary installation rollback",
		"root-owned policy state",
	}
	if len(privileged) != len(wantPrivileged) {
		t.Fatalf("privileged checks = %v, want %v", privileged, wantPrivileged)
	}
	for index, name := range wantPrivileged {
		if privileged[index] != name {
			t.Fatalf("privileged checks = %v, want %v", privileged, wantPrivileged)
		}
	}
}

func TestPrivilegedInstallerCurlTransportBounds(t *testing.T) {
	if _, err := exec.LookPath("curl"); err != nil {
		t.Skip("curl is not installed")
	}

	var targetHits atomic.Int32
	target := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		targetHits.Add(1)
		_, _ = io.WriteString(response, "printf 'unexpected redirect target reached\\n'\n")
	}))
	defer target.Close()

	tlsRedirect := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		http.Redirect(response, &http.Request{}, target.URL+"/downgrade", http.StatusFound)
	}))
	defer tlsRedirect.Close()
	caFile := filepath.Join(t.TempDir(), "ca.pem")
	certificate := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: tlsRedirect.Certificate().Raw})
	if err := os.WriteFile(caFile, certificate, 0o600); err != nil {
		t.Fatal(err)
	}

	assertCurlProtocolRefusal(t, []string{
		"--proto", "=https", "--proto-redir", "=https", "--globoff", "-fsSL",
		"--cacert", caFile, tlsRedirect.URL,
	})
	if hits := targetHits.Load(); hits != 0 {
		t.Fatalf("HTTPS downgrade reached the plaintext target %d times", hits)
	}

	httpRedirect := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		http.Redirect(response, &http.Request{}, target.URL+"/plaintext", http.StatusFound)
	}))
	defer httpRedirect.Close()
	assertCurlProtocolRefusal(t, append(privateHTTPCurlArgs(), httpRedirect.URL))
	if hits := targetHits.Load(); hits != 0 {
		t.Fatalf("private HTTP redirect reached the plaintext target %d times", hits)
	}

	fileRedirect := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		response.Header().Set("Location", "file:///tmp/emisar-installtest-never-read")
		response.WriteHeader(http.StatusFound)
	}))
	defer fileRedirect.Close()
	assertCurlProtocolRefusal(t, append(privateHTTPCurlArgs(), fileRedirect.URL))

	direct := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(response, "printf 'local install fetched\\n'\n")
	}))
	defer direct.Close()
	result := exec.Command("curl", append(privateHTTPCurlArgs(), direct.URL)...)
	output, err := result.CombinedOutput()
	if err != nil {
		t.Fatalf("direct private HTTP fetch failed: %v\n%s", err, output)
	}
	if !strings.Contains(string(output), "local install fetched") {
		t.Fatalf("direct private HTTP output = %q", output)
	}
}

func privateHTTPCurlArgs() []string {
	return []string{"--proto", "=http,https", "--proto-redir", "=https", "--globoff", "-fsSL"}
}

func assertCurlProtocolRefusal(t *testing.T, args []string) {
	t.Helper()
	output, err := exec.Command("curl", args...).CombinedOutput()
	if err == nil {
		t.Fatalf("curl unexpectedly followed a refused redirect:\n%s", output)
	}
	if code := exitCode(err); code != 1 {
		t.Fatalf("curl refusal exited %d, expected protocol error 1:\n%s", code, output)
	}
}
