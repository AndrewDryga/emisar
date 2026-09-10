//go:build !windows

package devtool

import (
	"bytes"
	"crypto/sha256"
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

// These tests execute the shipped entrypoints with real curl. A local HTTP
// fault server supplements (not replaces) each provider's behavior fixture.
// In particular, an unused large JSON field must be refused BEFORE projection.
type responsePack struct {
	name, script, path, header, credential string
	args, env                              []string
	limit                                  int64
	prefix, suffix                         string
	passthrough, newline, emptyOK          bool
}

func responsePacks() []responsePack {
	return []responsePack{
		{name: "databricks", script: "databricks/scripts/databricks.sh", args: []string{"whoami"}, path: "/api/2.0/preview/scim/v2/Me", env: []string{"DATABRICKS_HOST=%s", "DATABRICKS_TOKEN=response-fixture-token"}, header: "Authorization", credential: "Bearer response-fixture-token", limit: 32 << 20, prefix: `{"id":"fixture","userName":"fixture","padding":"`, suffix: `"}`},
		{name: "hcp-terraform", script: "hcp-terraform/scripts/tfc.sh", args: []string{"list_organizations", "20", "1"}, path: "/api/v2/organizations", env: []string{"TFE_ADDRESS=%s", "TFE_TOKEN=response-fixture-token"}, header: "Authorization", credential: "Bearer response-fixture-token", limit: 32 << 20, prefix: `{"data":[{"id":"fixture","attributes":{}}],"padding":"`, suffix: `"}`},
		{name: "spark", script: "spark/scripts/spark_api.sh", args: []string{"version", "history"}, path: "/api/v1/version", env: []string{"SPARK_HISTORY_URL=%s", "SPARK_API_TOKEN=response-fixture-token"}, header: "Authorization", credential: "Bearer response-fixture-token", limit: 32 << 20, prefix: `{"version":"fixture","padding":"`, suffix: `"}`, passthrough: true, emptyOK: true},
		{name: "cloudflare", script: "cloudflare/scripts/cf_api.sh", args: []string{"list-accounts", "1", "20"}, path: "/client/v4/accounts", env: []string{"CF_PACKTEST=1", "CF_API_BASE=http://cloudflare-api:8080/client/v4", "CF_API_TOKEN=response-fixture-token", "http_proxy=%s"}, header: "Authorization", credential: "Bearer response-fixture-token", limit: 16 << 20, prefix: `{"success":true,"result":[{"id":"fixture"}],"padding":"`, suffix: `"}`, passthrough: true, newline: true},
		{name: "bunnycdn", script: "bunnycdn/scripts/bunny_api.sh", args: []string{"list-regions"}, path: "/core/region", env: []string{"BUNNY_PACKTEST=1", "BUNNY_CORE_API_BASE=http://bunny-api:8080/core", "BUNNY_LOGGING_API_BASE=http://bunny-api:8080/logging", "BUNNY_ORIGIN_ERRORS_API_BASE=http://bunny-api:8080/origin", "BUNNY_API_KEY=response-fixture-token", "http_proxy=%s"}, header: "AccessKey", credential: "response-fixture-token", limit: 16 << 20, prefix: `[{"Name":"fixture","padding":"`, suffix: `"}]`, passthrough: true, newline: true},
		{name: "airflow", script: "airflow/scripts/airflow_api.sh", args: []string{"dag", "fixture"}, path: "/api/v2/dags/fixture", env: []string{"AIRFLOW_URL=%s", "AIRFLOW_API_TOKEN=response-fixture-token"}, header: "Authorization", credential: "Bearer response-fixture-token", limit: 32 << 20, prefix: `{"dag_id":"fixture","padding":"`, suffix: `"}`, passthrough: true, emptyOK: true},
		{name: "pfsense", script: "pfsense/scripts/pfproject.sh", args: []string{"/api/v2/system/certificates", ".data = [(.data // [])[] | {descr, refid, caref, type, valid_from, valid_until, valid_days_left}]"}, path: "/api/v2/system/certificates", env: []string{"PFSENSE_URL=%s", "PFSENSE_API_KEY=response-fixture-token"}, header: "X-API-Key", credential: "response-fixture-token", limit: 32 << 20, prefix: `{"data":[{"descr":"fixture","prv":"`, suffix: `"}]}`, emptyOK: true},
	}
}

// Build exact byte lengths without allocating a second response-sized buffer.
func responseBody(pack responsePack, size int64, unicode bool) io.Reader {
	padding := size - int64(len(pack.prefix)+len(pack.suffix))
	unit := "x"
	if unicode {
		unit = "🙂"
	}
	whole := padding / int64(len(unit)) * int64(len(unit))
	return io.MultiReader(strings.NewReader(pack.prefix), io.LimitReader(&repeatingResponse{block: []byte(strings.Repeat(unit, 8192))}, whole), strings.NewReader(strings.Repeat("x", int(padding-whole))), strings.NewReader(pack.suffix))
}

type repeatingResponse struct {
	block  []byte
	offset int
}

func (r *repeatingResponse) Read(p []byte) (int, error) {
	n := copy(p, r.block[r.offset:])
	r.offset = (r.offset + n) % len(r.block)
	return n, nil
}

// HTTP framing is deliberate: curl's historical --max-filesize only covered
// advertised lengths. The script's cap+1 reader must also cover the other two.
func serveResponse(w http.ResponseWriter, r *http.Request, framing string, size int64, body io.Reader) {
	w.Header().Set("Content-Type", "application/json")
	switch framing {
	case "length":
		w.Header().Set("Content-Length", strconv.FormatInt(size, 10))
	case "chunked":
		w.(http.Flusher).Flush()
	case "close":
		conn, rw, err := w.(http.Hijacker).Hijack()
		if err != nil {
			return
		}
		defer conn.Close()
		_, _ = rw.WriteString("HTTP/1.0 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n")
		_, _ = io.Copy(rw, body)
		_ = rw.Flush()
		return
	}
	_, _ = io.Copy(w, body) // An over-limit client deliberately closes early.
}

type responseOutput struct {
	count int64
	first bytes.Buffer
}

func (out *responseOutput) Write(p []byte) (int, error) {
	out.count += int64(len(p))
	if remaining := 4096 - out.first.Len(); remaining > 0 {
		_, _ = out.first.Write(p[:min(len(p), remaining)])
	}
	return len(p), nil
}

func responseCommand(t *testing.T, pack responsePack, address, temp string) *exec.Cmd {
	t.Helper()
	for _, binary := range []string{"bash", "curl", "jq"} {
		if _, err := exec.LookPath(binary); err != nil {
			t.Fatalf("complete pack response tests require %s: %v", binary, err)
		}
	}
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	interpreter := "bash"
	if pack.name == "pfsense" {
		interpreter = "/bin/sh"
	}
	cmd := exec.Command(interpreter, append([]string{filepath.Join(root, "packs", pack.script)}, pack.args...)...)
	// No inherited credentials, curl configuration, or forwarding proxies.
	cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "HOME=" + temp, "TMPDIR=" + temp, "LC_ALL=C", "no_proxy=", "NO_PROXY="}
	for _, env := range pack.env {
		cmd.Env = append(cmd.Env, strings.ReplaceAll(env, "%s", address))
	}
	configureProcessGroup(cmd)
	return cmd
}

func waitResponseCommand(t *testing.T, cmd *exec.Cmd) error {
	t.Helper()
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	return awaitResponseCommand(t, cmd)
}

func awaitResponseCommand(t *testing.T, cmd *exec.Cmd) error {
	t.Helper()
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		return err
	case <-time.After(30 * time.Second):
		_ = stopProcessGroup(cmd, false)
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			_ = stopProcessGroup(cmd, true)
			<-done
		}
		t.Fatal("pack response subprocess exceeded 30 seconds")
		return nil
	}
}

func assertResponseCleanup(t *testing.T, temp string) {
	t.Helper()
	entries, err := os.ReadDir(temp)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("response scratch files survived: %v", entries)
	}
}

func assertResponseRequest(t *testing.T, pack responsePack, r *http.Request) {
	t.Helper()
	if r.URL.Path != pack.path || r.Header.Get(pack.header) != pack.credential {
		t.Errorf("unexpected request path/auth: path=%q header=%q", r.URL.Path, r.Header.Get(pack.header))
	}
	if pack.name == "cloudflare" && r.Host != "cloudflare-api:8080" || pack.name == "bunnycdn" && r.Host != "bunny-api:8080" {
		t.Errorf("fixture destination pin changed: %q", r.Host)
	}
}

func TestPackResponseByteBounds(t *testing.T) {
	for _, pack := range responsePacks() {
		for _, framing := range []string{"length", "chunked", "close"} {
			for _, delta := range []int64{-1, 0, 1} {
				t.Run(fmt.Sprintf("%s/%s/cap%+d", pack.name, framing, delta), func(t *testing.T) {
					size := pack.limit + delta
					server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
						assertResponseRequest(t, pack, r)
						serveResponse(w, r, framing, size, responseBody(pack, size, true))
					}))
					defer server.Close()
					temp := t.TempDir()
					cmd := responseCommand(t, pack, server.URL, temp)
					var out, stderr responseOutput
					digest := sha256.New()
					cmd.Stdout, cmd.Stderr = io.MultiWriter(&out, digest), &stderr
					err := waitResponseCommand(t, cmd)
					assertResponseCleanup(t, temp)
					if delta > 0 {
						if err == nil || !strings.Contains(stderr.first.String(), "response exceeded") || out.count != 0 {
							t.Fatalf("oversize response: err=%v stdout bytes=%d stderr=%s", err, out.count, &stderr.first)
						}
						return
					}
					if err != nil {
						t.Fatalf("bounded response failed: %v: %s", err, &stderr.first)
					}
					if pack.passthrough {
						expected := sha256.New()
						_, _ = io.Copy(expected, responseBody(pack, size, true))
						if pack.newline {
							_, _ = io.WriteString(expected, "\n")
						}
						if !bytes.Equal(digest.Sum(nil), expected.Sum(nil)) {
							t.Fatalf("successful response changed bytes (stdout=%d)", out.count)
						}
					} else if out.count > 2048 || !strings.Contains(out.first.String(), "fixture") {
						t.Fatalf("projection lost fixture or retained unused payload: %s", &out.first)
					}
				})
			}
		}
	}
}

func TestPackResponseTransferFailures(t *testing.T) {
	for _, pack := range responsePacks() {
		for _, scenario := range []string{"401", "403", "500", "disconnect", "empty"} {
			t.Run(pack.name+"/"+scenario, func(t *testing.T) {
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					assertResponseRequest(t, pack, r)
					if scenario == "empty" {
						w.WriteHeader(http.StatusNoContent)
					} else if scenario == "disconnect" {
						conn, rw, err := w.(http.Hijacker).Hijack()
						if err != nil {
							return
						}
						defer conn.Close()
						_, _ = rw.WriteString("HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\n{}")
						_ = rw.Flush()
					} else {
						status, _ := strconv.Atoi(scenario)
						http.Error(w, `{"error":"fixture rejected"}`, status)
					}
				}))
				defer server.Close()
				temp := t.TempDir()
				cmd := responseCommand(t, pack, server.URL, temp)
				var out, stderr responseOutput
				cmd.Stdout, cmd.Stderr = &out, &stderr
				err := waitResponseCommand(t, cmd)
				wantSuccess := scenario == "empty" && pack.emptyOK
				if (err == nil) != wantSuccess || out.count != 0 {
					t.Fatalf("failure/empty contract changed: err=%v stdout=%s stderr=%s", err, &out.first, &stderr.first)
				}
				assertResponseCleanup(t, temp)
			})
		}
	}
}

// jq 1.6 exits zero when it receives no input, while newer jq releases exit 4.
// The pack decides whether an API response is present; a runner's jq version
// must not turn an empty response into a successful action.
func TestPackResponseRejectsEmptyWhenJQAcceptsIt(t *testing.T) {
	for _, pack := range responsePacks() {
		if pack.emptyOK || pack.name == "pfsense" {
			continue
		}
		t.Run(pack.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				assertResponseRequest(t, pack, r)
				w.WriteHeader(http.StatusNoContent)
			}))
			defer server.Close()

			bin := t.TempDir()
			if err := os.WriteFile(filepath.Join(bin, "jq"), []byte("#!/bin/sh\ncat >/dev/null\nexit 0\n"), 0o755); err != nil {
				t.Fatal(err)
			}
			temp := t.TempDir()
			cmd := responseCommand(t, pack, server.URL, temp)
			for index, value := range cmd.Env {
				if strings.HasPrefix(value, "PATH=") {
					cmd.Env[index] = "PATH=" + bin + string(os.PathListSeparator) + strings.TrimPrefix(value, "PATH=")
				}
			}
			var stderr responseOutput
			cmd.Stderr = &stderr
			if err := waitResponseCommand(t, cmd); err == nil || !strings.Contains(stderr.first.String(), "empty response") {
				t.Fatalf("empty response succeeded with jq 1.6 semantics: err=%v stderr=%s", err, &stderr.first)
			}
			assertResponseCleanup(t, temp)
		})
	}
}

func TestPackResponseCancellationCleanup(t *testing.T) {
	for _, pack := range responsePacks() {
		t.Run(pack.name, func(t *testing.T) {
			entered := make(chan struct{})
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				assertResponseRequest(t, pack, r)
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
				t.Fatal("response did not begin")
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
					t.Errorf("response path is not private: %s %v", path, err)
				}
			}
			_ = stopProcessGroup(cmd, false)
			if err := awaitResponseCommand(t, cmd); err == nil {
				t.Error("terminated transfer succeeded")
			}
			assertResponseCleanup(t, temp)
		})
	}
}

func TestPackResponseAirflowToken(t *testing.T) {
	for _, scenario := range []string{"mint", "mint-cap", "explicit", "oversize-length", "oversize-chunked", "oversize-close", "denied"} {
		t.Run(scenario, func(t *testing.T) {
			pack := responsePacks()[5]
			pack.env = []string{"AIRFLOW_URL=%s", "AIRFLOW_USERNAME=fixture-user", "AIRFLOW_PASSWORD=fixture-password"}
			if scenario == "explicit" {
				pack.env = append(pack.env, "AIRFLOW_API_TOKEN=response-fixture-token")
			}
			var minted, reads atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/auth/token" {
					minted.Add(1)
					body, _ := io.ReadAll(io.LimitReader(r.Body, 1024))
					if r.Method != "POST" || !bytes.Contains(body, []byte(`"password":"fixture-password"`)) || !bytes.Contains(body, []byte(`"username":"fixture-user"`)) {
						t.Errorf("mint credentials changed: %s %s", r.Method, body)
					}
					if scenario == "denied" {
						w.WriteHeader(http.StatusUnauthorized)
					} else if strings.HasPrefix(scenario, "oversize-") || scenario == "mint-cap" {
						token := pack
						token.prefix, token.suffix = `{"access_token":"response-fixture-token","padding":"`, `"}`
						size, framing := pack.limit+1, strings.TrimPrefix(scenario, "oversize-")
						if scenario == "mint-cap" {
							size, framing = pack.limit, "chunked"
						}
						serveResponse(w, r, framing, size, responseBody(token, size, true))
					} else {
						_, _ = io.WriteString(w, `{"access_token":"response-fixture-token"}`)
					}
					return
				}
				reads.Add(1)
				assertResponseRequest(t, pack, r)
				_, _ = io.WriteString(w, `{"dag_id":"fixture"}`)
			}))
			defer server.Close()
			temp := t.TempDir()
			cmd := responseCommand(t, pack, server.URL, temp)
			var out, stderr responseOutput
			cmd.Stdout, cmd.Stderr = &out, &stderr
			err := waitResponseCommand(t, cmd)
			wantRead := scenario == "mint" || scenario == "mint-cap" || scenario == "explicit"
			if (err == nil) != wantRead || (reads.Load() == 1) != wantRead || (minted.Load() == 0) != (scenario == "explicit") {
				t.Fatalf("token flow: err=%v mint=%d reads=%d stderr=%s", err, minted.Load(), reads.Load(), &stderr.first)
			}
			assertResponseCleanup(t, temp)
		})
	}
}

type countedResponseReader struct {
	io.Reader
	read atomic.Int64
}

func (r *countedResponseReader) Read(p []byte) (int, error) {
	n, err := r.Reader.Read(p)
	r.read.Add(int64(n))
	return n, err
}

func TestPackResponseStopsOversizeProducer(t *testing.T) {
	for _, pack := range responsePacks() {
		t.Run(pack.name, func(t *testing.T) {
			body := &countedResponseReader{Reader: responseBody(pack, pack.limit*4, true)}
			finished := make(chan struct{})
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				defer close(finished)
				assertResponseRequest(t, pack, r)
				serveResponse(w, r, "chunked", pack.limit*4, body)
			}))
			defer server.Close()
			temp := t.TempDir()
			cmd := responseCommand(t, pack, server.URL, temp)
			var out, stderr responseOutput
			cmd.Stdout, cmd.Stderr = &out, &stderr
			if err := waitResponseCommand(t, cmd); err == nil || out.count != 0 || !strings.Contains(stderr.first.String(), "response exceeded") {
				t.Fatalf("oversize producer succeeded: err=%v stdout=%d stderr=%s", err, out.count, &stderr.first)
			}
			select {
			case <-finished:
			case <-time.After(5 * time.Second):
				t.Fatal("producer kept streaming after the response was refused")
			}
			// Socket and HTTP buffers can read ahead. Do not confuse that with
			// the strict cap+1 scratch-file bound or require byte-exact network IO.
			if body.read.Load() > pack.limit+(8<<20) {
				t.Fatalf("producer was drained rather than stopped: read=%d cap=%d", body.read.Load(), pack.limit)
			}
			assertResponseCleanup(t, temp)
		})
	}
}

func TestPackResponsePinnedDestinationsAndEnvelope(t *testing.T) {
	for _, index := range []int{3, 4} {
		pack := responsePacks()[index]
		t.Run(pack.name+"/arbitrary-base", func(t *testing.T) {
			var requests atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { requests.Add(1) }))
			defer server.Close()
			pack.env = append([]string(nil), pack.env...)
			for i, env := range pack.env {
				if strings.HasPrefix(env, "CF_API_BASE=") || strings.HasPrefix(env, "BUNNY_CORE_API_BASE=") {
					pack.env[i] = strings.SplitN(env, "=", 2)[0] + "=" + server.URL
				}
			}
			temp := t.TempDir()
			cmd := responseCommand(t, pack, server.URL, temp)
			var stderr responseOutput
			cmd.Stderr = &stderr
			if err := waitResponseCommand(t, cmd); err == nil || requests.Load() != 0 {
				t.Fatalf("arbitrary destination accepted: err=%v requests=%d stderr=%s", err, requests.Load(), &stderr.first)
			}
			assertResponseCleanup(t, temp)
		})
	}
	t.Run("cloudflare/unsuccessful-envelope", func(t *testing.T) {
		pack := responsePacks()[3]
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			assertResponseRequest(t, pack, r)
			_, _ = io.WriteString(w, `{"success":false,"errors":[{"message":"denied"}]}`)
		}))
		defer server.Close()
		temp := t.TempDir()
		cmd := responseCommand(t, pack, server.URL, temp)
		var stderr responseOutput
		cmd.Stderr = &stderr
		if err := waitResponseCommand(t, cmd); err == nil || !strings.Contains(stderr.first.String(), "reported failure") {
			t.Fatalf("false envelope succeeded: err=%v stderr=%s", err, &stderr.first)
		}
		assertResponseCleanup(t, temp)
	})
}

func TestPackResponseHCPRedirects(t *testing.T) {
	for _, scenario := range []string{"one-hop", "second-hop", "oversize"} {
		t.Run(scenario, func(t *testing.T) {
			pack := responsePacks()[1]
			pack.args = []string{"plan_summary", "run-fixture"}
			pack.path = "/api/v2/runs/run-fixture/plan/json-output"
			var reads, unexpected atomic.Int32
			blob := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				reads.Add(1)
				if r.Header.Get("Authorization") != "" {
					t.Error("bearer credential leaked to cross-host redirect")
				}
				if r.URL.Path != "/plan" {
					unexpected.Add(1)
				}
				if scenario == "second-hop" {
					http.Redirect(w, r, "/forbidden", http.StatusFound)
				} else {
					pack.prefix, pack.suffix = `{"format_version":"1.2","terraform_version":"fixture","padding":"`, `"}`
					size := int64(128)
					if scenario == "oversize" {
						size = pack.limit + 1
					}
					serveResponse(w, r, "chunked", size, responseBody(pack, size, true))
				}
			}))
			defer blob.Close()
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				assertResponseRequest(t, pack, r)
				// A different hostname is necessary: a changed port alone does
				// not exercise curl's cross-host authorization rule.
				http.Redirect(w, r, strings.Replace(blob.URL, "127.0.0.1", "localhost", 1)+"/plan", http.StatusFound)
			}))
			defer server.Close()
			temp := t.TempDir()
			cmd := responseCommand(t, pack, server.URL, temp)
			var out, stderr responseOutput
			cmd.Stdout, cmd.Stderr = &out, &stderr
			err := waitResponseCommand(t, cmd)
			if (err == nil) != (scenario == "one-hop") || reads.Load() != 1 || unexpected.Load() != 0 {
				t.Fatalf("redirect contract: err=%v reads=%d extra=%d stdout=%s stderr=%s", err, reads.Load(), unexpected.Load(), &out.first, &stderr.first)
			}
			if scenario == "one-hop" && !strings.Contains(out.first.String(), `"source":"hcp_plan"`) {
				t.Fatalf("plan projection missing: %s", &out.first)
			}
			assertResponseCleanup(t, temp)
		})
	}
}

func TestPackResponseEmptyMutation(t *testing.T) {
	for _, index := range []int{1, 4} {
		pack := responsePacks()[index]
		t.Run(pack.name, func(t *testing.T) {
			if pack.name == "hcp-terraform" {
				pack.args, pack.path = []string{"cancel", "run-fixture", ""}, "/api/v2/runs/run-fixture"
			} else {
				pack.args, pack.path = []string{"set-cache-behavior", "1", "smart_cache", "true"}, "/core/pullzone/1"
			}
			var mutations, reads atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get(pack.header) != pack.credential {
					t.Error("mutation lost credential")
				}
				if r.Method == "POST" {
					mutations.Add(1)
					if r.URL.Path != pack.path && r.URL.Path != pack.path+"/actions/cancel" {
						t.Errorf("unexpected mutation path %q", r.URL.Path)
					}
					w.WriteHeader(http.StatusNoContent)
				} else {
					reads.Add(1)
					assertResponseRequest(t, pack, r)
					if pack.name == "hcp-terraform" {
						_, _ = io.WriteString(w, `{"data":{"id":"run-fixture","attributes":{"status":"canceled"}}}`)
					} else {
						_, _ = io.WriteString(w, `{"Id":1,"Name":"fixture","Enabled":true}`)
					}
				}
			}))
			defer server.Close()
			temp := t.TempDir()
			cmd := responseCommand(t, pack, server.URL, temp)
			var out, stderr responseOutput
			cmd.Stdout, cmd.Stderr = &out, &stderr
			err := waitResponseCommand(t, cmd)
			if err != nil || mutations.Load() != 1 || reads.Load() != 1 || !strings.Contains(out.first.String(), "fixture") {
				t.Fatalf("empty mutation confirmation: err=%v post=%d get=%d stdout=%s stderr=%s", err, mutations.Load(), reads.Load(), &out.first, &stderr.first)
			}
			assertResponseCleanup(t, temp)
		})
	}
}
