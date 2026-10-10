//go:build !windows

package devtool

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const traefikFixtureRouter = `[{"name":"fixture@file","provider":"file","status":"enabled","rule":"Host(\u0060fixture.example\u0060)","service":"fixture"}]`
const traefikFixtureService = `[{"name":"fixture@file","provider":"file","status":"enabled","loadBalancer":{"servers":[{"url":"http://127.0.0.1:8082"}]}}]`

// Execute every shipped collection path, including both sides of the readiness
// join. Fault-server proof supplements the genuine >100-row Traefik fixture.
func traefikResponsePacks() []responsePack {
	var packs []responsePack
	for _, entry := range []struct {
		name, script, path string
		args               []string
	}{
		{"services", "trget.sh", "/api/http/services", []string{"/api/http/services"}},
		{"routers", "trget.sh", "/api/http/routers", []string{"/api/http/routers"}},
		{"summary", "http_services_summary.sh", "/api/http/services", []string{"false"}},
		{"readiness-routers", "host_readiness.sh", "/api/http/routers", []string{"fixture.example"}},
		{"readiness-services", "host_readiness.sh", "/api/http/services", []string{"fixture.example"}},
	} {
		fixture := traefikFixtureService
		if entry.path == "/api/http/routers" {
			fixture = traefikFixtureRouter
		}
		packs = append(packs, responsePack{
			name: "traefik/" + entry.name, script: "traefik/scripts/" + entry.script,
			path: entry.path, args: entry.args, limit: 4 << 20,
			env:    []string{"TRAEFIK_URL=%s", "TRAEFIK_BASICAUTH=fixture-user:fixture-password"},
			header: "Authorization", credential: "Basic Zml4dHVyZS11c2VyOmZpeHR1cmUtcGFzc3dvcmQ=",
			prefix: "[\n" + strings.TrimSuffix(strings.TrimPrefix(fixture, "["), "}]") + `,"padding":"`, suffix: `"}]`,
		})
	}
	return packs
}

func traefikInventoryRequest(t *testing.T, pack responsePack, r *http.Request) bool {
	t.Helper()
	query := r.URL.Query()
	if r.Method != http.MethodGet || r.Header.Get(pack.header) != pack.credential ||
		len(query) != 2 || query.Get("page") != "1" || query.Get("per_page") != "2147483647" {
		t.Errorf("inventory request lost GET, fixed query or stdin auth: method=%s path=%s query=%v", r.Method, r.URL.Path, query)
	}
	if r.URL.Path == pack.path {
		return true
	}
	if !strings.Contains(pack.name, "readiness-") ||
		(r.URL.Path != "/api/http/routers" && r.URL.Path != "/api/http/services") {
		t.Errorf("unexpected inventory path: %s", r.URL.Path)
	}
	return false
}

func traefikOtherCollection(w http.ResponseWriter, r *http.Request) {
	fixture := traefikFixtureService
	if r.URL.Path == "/api/http/routers" {
		fixture = traefikFixtureRouter
	}
	_, _ = io.WriteString(w, fixture)
}

func TestTraefikInventoryByteBounds(t *testing.T) {
	for _, pack := range traefikResponsePacks() {
		for _, framing := range []string{"length", "chunked", "close"} {
			for _, delta := range []int64{-1, 0, 1} {
				t.Run(fmt.Sprintf("%s/%s/cap%+d", pack.name, framing, delta), func(t *testing.T) {
					size := pack.limit + delta
					server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
						if !traefikInventoryRequest(t, pack, r) {
							traefikOtherCollection(w, r)
							return
						}
						serveResponse(w, r, framing, size, responseBody(pack, size, true))
					}))
					defer server.Close()
					temp := t.TempDir()
					cmd := responseCommand(t, pack, server.URL, temp)
					var out bytes.Buffer
					var stderr responseOutput
					cmd.Stdout, cmd.Stderr = &out, &stderr
					err := waitResponseCommand(t, cmd)
					assertResponseCleanup(t, temp)
					if delta > 0 {
						if err == nil || out.Len() != 0 || !strings.Contains(stderr.first.String(), "inventory exceeded 4 MiB") {
							t.Fatalf("oversized input was projected: err=%v output=%d stderr=%s", err, out.Len(), &stderr.first)
						}
						return
					}
					if err != nil || !json.Valid(out.Bytes()) || out.Len() > int(pack.limit) || !bytes.Contains(out.Bytes(), []byte("fixture@file")) {
						t.Fatalf("complete bounded array failed: err=%v output=%d stderr=%s", err, out.Len(), &stderr.first)
					}
					if strings.Contains(pack.name, "readiness-") && !bytes.Contains(out.Bytes(), []byte(`"ready":true`)) {
						t.Fatalf("large router/service collection lost readiness: %s", out.Bytes())
					}
				})
			}
		}
	}
}

func TestTraefikInventoryShapeAndTransferFailures(t *testing.T) {
	for _, pack := range traefikResponsePacks() {
		for _, scenario := range []string{"empty-array", "empty", "malformed", "multiple", "object", "401", "403", "500", "disconnect"} {
			t.Run(pack.name+"/"+scenario, func(t *testing.T) {
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					if !traefikInventoryRequest(t, pack, r) {
						traefikOtherCollection(w, r)
						return
					}
					switch scenario {
					case "empty-array":
						_, _ = io.WriteString(w, "[\n]\n")
					case "empty":
						w.WriteHeader(http.StatusNoContent)
					case "malformed":
						_, _ = io.WriteString(w, `[{"name":"incomplete"`)
					case "multiple":
						_, _ = io.WriteString(w, "[]\n[]")
					case "object":
						_, _ = io.WriteString(w, `{}`)
					case "disconnect":
						conn, rw, err := w.(http.Hijacker).Hijack()
						if err != nil {
							return
						}
						defer conn.Close()
						_, _ = rw.WriteString("HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\n[]")
						_ = rw.Flush()
					default:
						status, _ := strconv.Atoi(scenario)
						http.Error(w, "fixture rejection", status)
					}
				}))
				defer server.Close()
				temp := t.TempDir()
				cmd := responseCommand(t, pack, server.URL, temp)
				var out, stderr responseOutput
				cmd.Stdout, cmd.Stderr = &out, &stderr
				err := waitResponseCommand(t, cmd)
				if scenario == "empty-array" {
					if err != nil || !json.Valid(out.first.Bytes()) {
						t.Fatalf("valid empty collection failed: %v %s", err, &stderr.first)
					}
				} else if err == nil || out.count != 0 {
					t.Fatalf("invalid/failed inventory succeeded: err=%v output=%s stderr=%s", err, &out.first, &stderr.first)
				}
				assertResponseCleanup(t, temp)
			})
		}
	}
}

func TestTraefikInventoryLocalReaderFailures(t *testing.T) {
	for _, pack := range traefikResponsePacks() {
		for _, fault := range []struct{ name, binary, code string }{
			{"reader", "head", "cat >/dev/null\nprintf '[]'\nexit 7\n"},
			{"counter", "wc", "exit 7\n"},
			{"missing-status", "cat", "exit 7\n"},
			{"malformed-status", "cat", "printf 'not-an-exit-status'\n"},
			{"private-directory", "mktemp", "exit 7\n"},
		} {
			t.Run(pack.name+"/"+fault.name, func(t *testing.T) {
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					traefikInventoryRequest(t, pack, r)
					traefikOtherCollection(w, r)
				}))
				defer server.Close()
				bin := t.TempDir()
				if err := os.WriteFile(filepath.Join(bin, fault.binary), []byte("#!/bin/sh\n"+fault.code), 0o755); err != nil {
					t.Fatal(err)
				}
				temp := t.TempDir()
				cmd := responseCommand(t, pack, server.URL, temp)
				cmd.Env = append(cmd.Env, "PATH="+bin+string(os.PathListSeparator)+os.Getenv("PATH"))
				var out, stderr responseOutput
				cmd.Stdout, cmd.Stderr = &out, &stderr
				if err := waitResponseCommand(t, cmd); err == nil || out.count != 0 {
					t.Fatalf("reader/status failure emitted a verdict: err=%v stdout=%s stderr=%s", err, &out.first, &stderr.first)
				}
				assertResponseCleanup(t, temp)
			})
		}
	}
}

func TestTraefikInventoryCredentialsStayOffArgv(t *testing.T) {
	curl, err := exec.LookPath("curl")
	if err != nil {
		t.Fatal(err)
	}
	for _, pack := range traefikResponsePacks() {
		t.Run(pack.name, func(t *testing.T) {
			var reads atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				reads.Add(1)
				traefikInventoryRequest(t, pack, r)
				traefikOtherCollection(w, r)
			}))
			defer server.Close()
			bin := t.TempDir()
			wrapper := "#!/bin/sh\nfor arg do\ncase \"$arg\" in *fixture-password*|*Zml4dHVyZS11c2VyOmZpeHR1cmUtcGFzc3dvcmQ*) exit 90 ;; esac\ndone\nexec '" + strings.ReplaceAll(curl, "'", "'\\''") + "' \"$@\"\n"
			if err := os.WriteFile(filepath.Join(bin, "curl"), []byte(wrapper), 0o755); err != nil {
				t.Fatal(err)
			}
			temp := t.TempDir()
			cmd := responseCommand(t, pack, server.URL, temp)
			cmd.Env = append(cmd.Env, "PATH="+bin+string(os.PathListSeparator)+os.Getenv("PATH"))
			var out, stderr responseOutput
			cmd.Stdout, cmd.Stderr = &out, &stderr
			wantReads := int32(1)
			if strings.Contains(pack.name, "readiness-") {
				wantReads = 2
			}
			if err := waitResponseCommand(t, cmd); err != nil || reads.Load() != wantReads {
				t.Fatalf("stdin auth failed or entered argv: err=%v reads=%d stderr=%s", err, reads.Load(), &stderr.first)
			}
			assertResponseCleanup(t, temp)
		})
	}
}

func TestTraefikInventoryCancellationCleanup(t *testing.T) {
	for _, pack := range traefikResponsePacks() {
		t.Run(pack.name, func(t *testing.T) {
			entered := make(chan struct{})
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if !traefikInventoryRequest(t, pack, r) {
					traefikOtherCollection(w, r)
					return
				}
				_, _ = io.WriteString(w, pack.prefix)
				w.(http.Flusher).Flush()
				close(entered)
				<-r.Context().Done()
			}))
			defer server.Close()
			temp := t.TempDir()
			cmd := responseCommand(t, pack, server.URL, temp)
			var out, stderr responseOutput
			cmd.Stdout, cmd.Stderr = &out, &stderr
			if err := cmd.Start(); err != nil {
				t.Fatal(err)
			}
			select {
			case <-entered:
			case <-time.After(10 * time.Second):
				_ = stopProcessGroup(cmd, false)
				_ = awaitResponseCommand(t, cmd)
				t.Fatal("inventory transfer did not begin")
			}
			entries, err := os.ReadDir(temp)
			if err != nil || len(entries) != 1 {
				_ = stopProcessGroup(cmd, false)
				_ = awaitResponseCommand(t, cmd)
				t.Fatalf("expected one private response directory: %v %v", entries, err)
			}
			for _, path := range []string{filepath.Join(temp, entries[0].Name()), filepath.Join(temp, entries[0].Name(), "body")} {
				info, err := os.Stat(path)
				if err != nil || info.Mode().Perm()&0o077 != 0 {
					t.Errorf("inventory scratch file is not private: %s %v", path, err)
				}
			}
			_ = stopProcessGroup(cmd, false)
			if err := awaitResponseCommand(t, cmd); err == nil || out.count != 0 {
				t.Errorf("terminated transfer emitted a successful inventory: %v %s", err, &out.first)
			}
			assertResponseCleanup(t, temp)
		})
	}
}
