package hostscan

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func facts(bins map[string]string, running ...string) Facts {
	r := make(map[string]bool, len(running))
	for _, p := range running {
		r[p] = true
	}
	if bins == nil {
		bins = map[string]string{}
	}
	return Facts{Binaries: bins, Running: r}
}

func ids(s []Suggestion) []string {
	out := make([]string, len(s))
	for i, x := range s {
		out[i] = x.ID
	}
	return out
}

func TestMatch_AllRequiredBinariesMustBePresent(t *testing.T) {
	reqs := []PackReq{
		// consul needs both the consul CLI and curl — curl alone (a
		// near-ubiquitous helper) must NOT be enough to suggest it.
		{ID: "consul", OS: []string{runtime.GOOS}, Binaries: []string{"consul", "curl"}},
		{ID: "nomad", OS: []string{runtime.GOOS}, Binaries: []string{"nomad"}},
	}

	// Only curl present → neither matches.
	got := ids(Match(reqs, facts(map[string]string{"curl": "/usr/bin/curl"})))
	if len(got) != 0 {
		t.Fatalf("curl alone should match nothing, got %v", got)
	}

	// consul + curl present → consul matches; nomad still absent.
	got = ids(Match(reqs, facts(map[string]string{"curl": "/usr/bin/curl"}, "consul")))
	if want := []string{"consul"}; !equal(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestMatch_RunningProcessCountsAsPresent(t *testing.T) {
	// The binary isn't on any path we probed, but it's running — that's
	// the /usr/local/bin/nomad case: detect it anyway.
	reqs := []PackReq{{ID: "nomad", OS: []string{runtime.GOOS}, Binaries: []string{"nomad"}}}
	got := Match(reqs, facts(nil, "nomad"))
	if len(got) != 1 || got[0].ID != "nomad" {
		t.Fatalf("running process should match, got %v", ids(got))
	}
	if len(got[0].Evidence) != 1 || got[0].Evidence[0] != "nomad (running)" {
		t.Fatalf("evidence = %v, want [nomad (running)]", got[0].Evidence)
	}
}

func TestMatch_OSFilterAndEmptyBinariesSkip(t *testing.T) {
	reqs := []PackReq{
		{ID: "winthing", OS: []string{"windows"}, Binaries: []string{"nomad"}},
		{ID: "linux-core", OS: []string{"linux"}, Binaries: nil}, // baseline, no binaries
	}
	got := ids(Match(reqs, facts(nil, "nomad")))
	if len(got) != 0 {
		t.Fatalf("wrong-OS and empty-binaries packs must be skipped, got %v", got)
	}
}

func TestMatch_EmptyOSMatchesAnyHost(t *testing.T) {
	reqs := []PackReq{{ID: "anyos", OS: nil, Binaries: []string{"git"}}}
	if got := Match(reqs, facts(map[string]string{"git": "/usr/bin/git"})); len(got) != 1 {
		t.Fatalf("empty OS list should match host, got %v", ids(got))
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
	// A non-executable file must not count as a found binary.
	if err := os.WriteFile(filepath.Join(dir, "plain"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	// dir reached only via the standard-dirs fallback (empty PATH).
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
	// pid with absolute argv0 in cmdline → basename, untruncated.
	writeProc(t, proc, "100", "/usr/local/bin/nomad\x00agent\x00", "")
	// pid with only comm (kernel thread style).
	writeProc(t, proc, "200", "", "consul\n")
	// argv-rewriting daemon: cmdline basename is the rewritten title, but
	// comm still carries the real name — both must be recorded so the real
	// one (postgres) is detectable.
	writeProc(t, proc, "300", "postgres: writer process\x00", "postgres\n")
	// non-pid dirs and files are ignored.
	if err := os.MkdirAll(filepath.Join(proc, "self"), 0o755); err != nil {
		t.Fatal(err)
	}

	got := scanProcesses(proc)
	if !got["nomad"] {
		t.Fatalf("cmdline argv0 basename should be detected, got %v", got)
	}
	if !got["consul"] {
		t.Fatalf("comm-only process should be detected, got %v", got)
	}
	if !got["postgres"] {
		t.Fatalf("comm should be read even when cmdline is non-empty (argv rewrite), got %v", got)
	}
}

func TestScanProcesses_NoProcDirIsEmptyNotError(t *testing.T) {
	if got := scanProcesses(filepath.Join(t.TempDir(), "nope")); len(got) != 0 {
		t.Fatalf("missing proc root should yield empty set, got %v", got)
	}
}

func TestDetect_FindsHostGoBinary(t *testing.T) {
	// Integration smoke: the go toolchain that runs this test is on PATH,
	// so Detect must surface it. Keeps Detect()'s real wiring covered.
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
