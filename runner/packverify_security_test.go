package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// setup.verify runs automatically on install, `pack verify`, and
// `doctor --probe`, with no approval, on the promise that it is a low-risk
// read. A pack that points it at a riskier action must not get that action
// run as a side effect: the probe is skipped and the action never executes,
// even with no admission ceiling configured.
func TestPackVerify_NonLowRiskVerifyActionIsNeverRun(t *testing.T) {
	dir := t.TempDir()
	marker := filepath.Join(dir, "mutated")
	stageProbePacks(t, probePack{
		id: "risky", binary: "/bin/sh", argv: []string{"-c", "touch " + marker}, risk: "high",
	})

	out, err := runPackVerify(t)
	if err != nil {
		t.Fatalf("a skipped probe must not fail the run: %v\n%s", err, out)
	}
	if _, statErr := os.Stat(marker); !os.IsNotExist(statErr) {
		t.Fatalf("the high-risk verify action ran (stat err=%v):\n%s", statErr, out)
	}
	if !strings.Contains(out, "skipped") || !strings.Contains(out, "high risk") {
		t.Fatalf("want a skipped row naming the risk:\n%s", out)
	}
}

// The shipped iperf3 pack names iperf3.version, a read tiered medium, as its
// verify action. It is skipped with that explanation rather than probed.
func TestPackVerify_ShippedIperf3VersionIsSkipped(t *testing.T) {
	withFlags(t)
	withJSONOut(t, false)
	dir := t.TempDir()
	packDir := filepath.Join(dir, "packs")
	if err := os.CopyFS(filepath.Join(packDir, "iperf3"), os.DirFS(filepath.Join("..", "packs", "iperf3"))); err != nil {
		t.Fatalf("copy iperf3 pack: %v", err)
	}
	flagConfig = writeMinimalConfig(t, dir, packDir)

	out, err := runPackVerify(t, "iperf3")
	if err != nil {
		t.Fatalf("pack verify iperf3: %v\n%s", err, out)
	}
	if !strings.Contains(out, "skipped") || !strings.Contains(out, "iperf3.version") ||
		!strings.Contains(out, "medium risk") {
		t.Fatalf("want iperf3.version skipped as medium risk:\n%s", out)
	}
}
