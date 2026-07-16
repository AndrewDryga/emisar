package hostscan

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

// TestFirstExecutable_RequiresRegularExecutableFile — a name
// resolves only to a REGULAR file with an execute bit set. A directory of that
// name, or a present-but-non-executable file, must not count as the binary.
func TestFirstExecutable_RequiresRegularExecutableFile(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("unix execute-bit semantics do not apply on windows")
	}
	dir := t.TempDir()

	// A regular, executable file → found.
	exe := filepath.Join(dir, "nomad")
	if err := os.WriteFile(exe, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if got := firstExecutable("nomad", []string{dir}); got != exe {
		t.Fatalf("executable file should resolve to %q, got %q", exe, got)
	}

	// A present-but-non-executable file → not found.
	if err := os.WriteFile(filepath.Join(dir, "consul"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := firstExecutable("consul", []string{dir}); got != "" {
		t.Fatalf("non-executable file must not count, got %q", got)
	}

	// A directory named like the binary → not found (IsDir guard).
	if err := os.Mkdir(filepath.Join(dir, "vault"), 0o755); err != nil {
		t.Fatal(err)
	}
	if got := firstExecutable("vault", []string{dir}); got != "" {
		t.Fatalf("a directory must not count as an executable, got %q", got)
	}

	// An absent name → not found.
	if got := firstExecutable("absent", []string{dir}); got != "" {
		t.Fatalf("absent name must yield empty, got %q", got)
	}
}

// TestSystemdPresent_MatchesStat — SystemdPresent is exactly
// "is /run/systemd/system a directory?". It must never panic and must agree
// with a direct stat of that path on whatever host the test runs on.
func TestSystemdPresent_MatchesStat(t *testing.T) {
	want := false
	if fi, err := os.Stat("/run/systemd/system"); err == nil && fi.IsDir() {
		want = true
	}
	if got := SystemdPresent(); got != want {
		t.Fatalf("SystemdPresent() = %v, but stat of /run/systemd/system says %v", got, want)
	}
}

// TestScanBinaries_NamesNormalizedAndDeduped — probed names are
// lowercased, trimmed, and de-duplicated: ["GO"," go ","go"] probes a single
// "go", and the result is keyed by the normalized lowercase name.
func TestScanBinaries_NamesNormalizedAndDeduped(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("unix execute-bit semantics do not apply on windows")
	}
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "go"), []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	t.Setenv("PATH", "")
	got := scanBinaries([]string{"GO", " go ", "go"}, []string{dir})

	if len(got) != 1 {
		t.Fatalf("variants of one name should dedupe to a single probe, got %v", got)
	}
	if got["go"] == "" {
		t.Fatalf("result should be keyed by the normalized lowercase name, got %v", got)
	}
	// The mixed-case / padded originals must NOT appear as separate keys.
	for _, k := range []string{"GO", " go ", "Go"} {
		if _, ok := got[k]; ok {
			t.Fatalf("un-normalized key %q must not be present, got %v", k, got)
		}
	}
}

// BenchmarkDetect — Detect is a bounded read-only scan (PATH +
// standard dirs for the probed names, plus /proc when present); it never execs.
// Measures the scan cost over a realistic set of probe names on the build host.
func BenchmarkDetect(b *testing.B) {
	names := []string{"go", "consul", "nomad", "vault", "redis-cli", "docker", "definitely-absent-xyz"}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = Detect(names)
	}
}
