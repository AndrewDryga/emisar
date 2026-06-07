package hostscan

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func facts(bins map[string]string, running ...string) Facts {
	r := make(map[string]bool, len(running))
	for _, p := range running {
		r[strings.ToLower(p)] = true
	}
	if bins == nil {
		bins = map[string]string{}
	}
	return Facts{Binaries: bins, Running: r, Ports: map[int]bool{}}
}

func ids(s []Suggestion) []string {
	out := make([]string, len(s))
	for i, x := range s {
		out[i] = x.ID
	}
	return out
}

// TestMatch_AnyDetectSignalFires — a pack is recommended when ANY of its
// detect signals hits (binary present, process running, port listening),
// and never when none do.
func TestMatch_AnyDetectSignalFires(t *testing.T) {
	reqs := []PackReq{
		{ID: "grafana", OS: []string{runtime.GOOS}, Processes: []string{"grafana-server"}, Ports: []int{3000}},
		{ID: "consul", OS: []string{runtime.GOOS}, Binaries: []string{"consul"}},
	}

	// process signal
	if got := ids(Match(reqs, facts(nil, "grafana-server"))); !equal(got, []string{"grafana"}) {
		t.Fatalf("process signal: got %v", got)
	}
	// port signal
	f := facts(nil)
	f.Ports[3000] = true
	if got := ids(Match(reqs, f)); !equal(got, []string{"grafana"}) {
		t.Fatalf("port signal: got %v", got)
	}
	// binary signal
	if got := ids(Match(reqs, facts(map[string]string{"consul": "/usr/bin/consul"}))); !equal(got, []string{"consul"}) {
		t.Fatalf("binary signal: got %v", got)
	}
	// nothing present
	if got := Match(reqs, facts(nil)); len(got) != 0 {
		t.Fatalf("no signal should suggest nothing, got %v", ids(got))
	}
}

func TestMatch_EvidenceNamesEachSignal(t *testing.T) {
	r := []PackReq{{ID: "grafana", OS: []string{runtime.GOOS}, Processes: []string{"grafana-server"}, Ports: []int{3000}}}
	f := facts(nil, "grafana-server")
	f.Ports[3000] = true
	got := Match(r, f)
	if len(got) != 1 {
		t.Fatalf("expected 1 match, got %v", ids(got))
	}
	joined := strings.Join(got[0].Evidence, " ")
	if !strings.Contains(joined, "grafana-server (running)") || !strings.Contains(joined, ":3000 (listening)") {
		t.Fatalf("evidence should name both signals, got %q", joined)
	}
}

// TestMatch_NoSignalNeverSuggests — a pack with an empty detect signal is
// never recommended, even on a busy host. (The portal omits these from the
// index, but the runner must not invent a match either.)
func TestMatch_NoSignalNeverSuggests(t *testing.T) {
	r := []PackReq{{ID: "cloudflare", OS: []string{runtime.GOOS}}}
	if got := Match(r, facts(map[string]string{"curl": "/usr/bin/curl"}, "anything")); len(got) != 0 {
		t.Fatalf("empty-signal pack must never match, got %v", ids(got))
	}
}

func TestMatch_OSFilter(t *testing.T) {
	r := []PackReq{{ID: "winonly", OS: []string{"windows"}, Binaries: []string{"foo"}}}
	if got := Match(r, facts(map[string]string{"foo": "/x/foo"})); len(got) != 0 {
		t.Fatalf("wrong-OS pack must be skipped, got %v", ids(got))
	}
	r = []PackReq{{ID: "anyos", Binaries: []string{"foo"}}}
	if got := Match(r, facts(map[string]string{"foo": "/x/foo"})); len(got) != 1 {
		t.Fatalf("empty OS should match host, got %v", ids(got))
	}
}

func TestMatch_BinaryPresentViaPathOrRunning(t *testing.T) {
	r := []PackReq{{ID: "nomad", OS: []string{runtime.GOOS}, Binaries: []string{"nomad"}}}
	if got := Match(r, facts(nil, "nomad")); len(got) != 1 || got[0].Evidence[0] != "nomad (running)" {
		t.Fatalf("running binary: got %v", got)
	}
	got := Match(r, facts(map[string]string{"nomad": "/usr/local/bin/nomad"}))
	if len(got) != 1 || got[0].Evidence[0] != "nomad (/usr/local/bin/nomad)" {
		t.Fatalf("path binary: got %v", got)
	}
}

func TestMatch_StableIDOrder(t *testing.T) {
	reqs := []PackReq{
		{ID: "redis", Binaries: []string{"redis-cli"}},
		{ID: "docker", Binaries: []string{"docker"}},
		{ID: "consul", Binaries: []string{"consul"}},
	}
	got := ids(Match(reqs, facts(nil, "redis-cli", "docker", "consul")))
	if want := []string{"consul", "docker", "redis"}; !equal(got, want) {
		t.Fatalf("got %v, want sorted %v", got, want)
	}
}

func TestScanBinaries_PathAndStandardDirs(t *testing.T) {
	dir := t.TempDir()
	writeExe(t, filepath.Join(dir, "nomad"))
	writeExe(t, filepath.Join(dir, "consul"))
	if err := os.WriteFile(filepath.Join(dir, "plain"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	t.Setenv("PATH", "")
	got := scanBinaries([]string{"nomad", "consul", "plain", "absent"}, []string{dir})

	if got["nomad"] == "" || got["consul"] == "" {
		t.Fatalf("expected nomad+consul found via standard dirs, got %v", got)
	}
	if _, ok := got["plain"]; ok {
		t.Fatalf("non-executable file must not be reported, got %v", got)
	}
	if _, ok := got["absent"]; ok {
		t.Fatalf("missing binary must not be reported, got %v", got)
	}
}

func TestScanProcesses_ReadsCmdlineAndComm(t *testing.T) {
	proc := t.TempDir()
	writeProc(t, proc, "100", "/usr/local/bin/nomad\x00agent\x00", "")
	writeProc(t, proc, "200", "", "consul\n")
	// argv-rewriting daemon: cmdline basename is the rewritten title, comm
	// still carries the real name — both must be recorded.
	writeProc(t, proc, "300", "postgres: writer process\x00", "postgres\n")
	if err := os.MkdirAll(filepath.Join(proc, "self"), 0o755); err != nil {
		t.Fatal(err)
	}

	got := scanProcesses(proc)
	for _, want := range []string{"nomad", "consul", "postgres"} {
		if !got[want] {
			t.Fatalf("expected %q detected, got %v", want, got)
		}
	}
}

func TestScanProcesses_NoProcDirIsEmptyNotError(t *testing.T) {
	if got := scanProcesses(filepath.Join(t.TempDir(), "nope")); len(got) != 0 {
		t.Fatalf("missing proc root should yield empty set, got %v", got)
	}
}

func TestScanPorts_ParsesListenSockets(t *testing.T) {
	proc := t.TempDir()
	netDir := filepath.Join(proc, "net")
	if err := os.MkdirAll(netDir, 0o755); err != nil {
		t.Fatal(err)
	}
	// header, a LISTEN socket on 0x1F90 (8080), and an ESTABLISHED one (st
	// 01, port 0x0050 = 80) that must be ignored.
	tcp := "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n" +
		"   0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000 0 12345 1\n" +
		"   1: 0100007F:0050 0100007F:ABCD 01 00000000:00000000 00:00000000 00000000  1000 0 12346 1\n"
	if err := os.WriteFile(filepath.Join(netDir, "tcp"), []byte(tcp), 0o644); err != nil {
		t.Fatal(err)
	}
	// tcp6 LISTEN on 0x2382 (9090).
	tcp6 := "  sl  local_address rem_address st others\n" +
		"   0: 00000000000000000000000000000000:2382 00000000000000000000000000000000:0000 0A 0 0 0 0 0 1\n"
	if err := os.WriteFile(filepath.Join(netDir, "tcp6"), []byte(tcp6), 0o644); err != nil {
		t.Fatal(err)
	}

	ports := scanPorts(proc)
	if !ports[8080] {
		t.Fatalf("expected :8080 LISTEN (tcp), got %v", ports)
	}
	if !ports[9090] {
		t.Fatalf("expected :9090 LISTEN (tcp6), got %v", ports)
	}
	if ports[80] {
		t.Fatalf("ESTABLISHED :80 must not count as listening, got %v", ports)
	}
}

func TestScanPorts_NoFileIsEmptyNotError(t *testing.T) {
	if got := scanPorts(filepath.Join(t.TempDir(), "nope")); len(got) != 0 {
		t.Fatalf("missing proc/net should yield empty set, got %v", got)
	}
}

func TestDetect_FindsHostGoBinary(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("path semantics differ on windows")
	}
	f := Detect([]string{"go", "definitely-not-a-real-binary-xyz"})
	if f.Binaries["go"] == "" {
		t.Fatalf("expected to find the go binary on PATH, got %v", f.Binaries)
	}
	if _, ok := f.Binaries["definitely-not-a-real-binary-xyz"]; ok {
		t.Fatalf("must not invent a missing binary")
	}
}

func writeExe(t *testing.T, path string) {
	t.Helper()
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
}

func writeProc(t *testing.T, root, pid, cmdline, comm string) {
	t.Helper()
	dir := filepath.Join(root, pid)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if cmdline != "" {
		if err := os.WriteFile(filepath.Join(dir, "cmdline"), []byte(cmdline), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if comm != "" {
		if err := os.WriteFile(filepath.Join(dir, "comm"), []byte(comm), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func equal(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
