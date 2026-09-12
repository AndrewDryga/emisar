package icons

import (
	"bytes"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The committed SVGs are the JavaScript normalizer's output; these pin the
// number semantics that decide whether Go reproduces them byte for byte.
func TestNumberSemanticsMatchJavaScript(t *testing.T) {
	t.Parallel()
	rounds := []struct{ in, want float64 }{
		{2.5, 3}, {-2.5, -2}, {-0.4, 0}, {0.49999999999999994, 0}, {-3.5, -3},
	}
	for _, c := range rounds {
		if got := jsRound(c.in); got != c.want {
			t.Errorf("jsRound(%v) = %v, want %v", c.in, got, c.want)
		}
	}
	formats := []struct {
		in   float64
		want string
	}{
		{12, "12"}, {1.5, "1.5"}, {0.125, "0.13"}, {-0.001, "0"}, {7.005, "7.01"}, {-0, "0"},
	}
	for _, c := range formats {
		if got := format(c.in); got != c.want {
			t.Errorf("format(%v) = %q, want %q", c.in, got, c.want)
		}
	}
	fixed := []struct {
		in     float64
		digits int
		want   float64
	}{
		{0.125, 2, 0.13}, {-0.125, 2, -0.13}, {12.345, 2, 12.35}, {0.9675, 3, 0.968}, {-0.0001, 2, 0},
	}
	for _, c := range fixed {
		if got := toFixed(c.in, c.digits); got != c.want {
			t.Errorf("toFixed(%v, %d) = %v, want %v", c.in, c.digits, got, c.want)
		}
	}
	// The JavaScript divided 1.5 by 1.55 at runtime. Folding that back into a Go
	// constant expression evaluates it exactly and lands one ulp high (…ef8).
	if bits := math.Float64bits(strokeFactor); bits != 0x3feef7bdef7bdef7 {
		t.Errorf("strokeFactor bits = %016x, want 3feef7bdef7bdef7", bits)
	}
}

func TestRebuildPathAbsolutizesAndSnaps(t *testing.T) {
	t.Parallel()
	snap := transform{
		x: halfGrid, y: halfGrid, controlX: quarterGrid, controlY: quarterGrid, radius: halfGrid, dot: halfGrid,
	}
	cases := []struct{ in, want string }{
		// A relative opener is absolute; the pairs after it are implicit linetos.
		{"m6.4 17.1-2.5-4.3 2.6 1.3", "M6.5 17L4 13L6.5 14"},
		{"M2 2h4v4.3z", "M2 2H6V6.5Z"},
		// Control points quarter-snap, endpoints half-snap, arc radii half-snap.
		{"M1 1c1.1 0.3 2.2 0.3 3.1 0.4", "M1 1C2 1.25 3.25 1.25 4 1.5"},
		{"M2 8a6.2 6.2 0 1 0 12.3 0", "M2 8A6 6 0 1 0 14.5 8"},
	}
	for _, c := range cases {
		got, err := rebuildPath(c.in, snap)
		if err != nil {
			t.Errorf("rebuildPath(%q): %v", c.in, err)
			continue
		}
		if got != c.want {
			t.Errorf("rebuildPath(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// A hand-edited master can hold a command short of its operands. Both tokenizers
// have to report that, because the JavaScript they port carried the short read
// through as NaN and Go indexes out of range instead.
func TestTruncatedPathIsAnErrorNotAPanic(t *testing.T) {
	t.Parallel()
	snap := transform{
		x: halfGrid, y: halfGrid, controlX: quarterGrid, controlY: quarterGrid, radius: halfGrid, dot: halfGrid,
	}
	// A cubic missing its final coordinate, an arc missing its endpoint, and a
	// lineto with an odd operand count.
	for _, d := range []string{"M1 1C1 2 3 4 5", "M2 8A6 6 0 1 0 14", "M1 1L4"} {
		if _, err := parsePath(d); err == nil {
			t.Errorf("parsePath(%q) = nil error, want a malformed-path error", d)
		}
		if _, err := rebuildPath(d, snap); err == nil {
			t.Errorf("rebuildPath(%q) = nil error, want a malformed-path error", d)
		}
	}
	// A well-formed path still parses.
	if _, err := parsePath("M1 1C1 2 3 4 5 6"); err != nil {
		t.Errorf("a well-formed cubic errored: %v", err)
	}
}

// The error a caller sees names the icon it came from, so an operator can find
// the master that needs fixing.
func TestMalformedMasterNamesTheIcon(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "state"), 0o755); err != nil {
		t.Fatal(err)
	}
	master := `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">
  <path d="M8 12.2C11 15 16 9"/>
</svg>
`
	if err := os.WriteFile(filepath.Join(root, "state/broken.svg"), []byte(master), 0o644); err != nil {
		t.Fatal(err)
	}

	_, err := Snap(root)
	if err == nil || !strings.Contains(err.Error(), "state/broken") {
		t.Fatalf("Snap error = %v, want one naming state/broken", err)
	}
	if _, err := Cut(root); err == nil || !strings.Contains(err.Error(), "state/broken") {
		t.Fatalf("Cut error = %v, want one naming state/broken", err)
	}

	// Analyze reads the 16-grid cuts, and names them with the dotted token.
	cut := `<svg viewBox="0 0 16 16"><path d="M5.5 8C7.5 10 10.5"/></svg>`
	if err := os.WriteFile(filepath.Join(root, "state/broken.16.svg"), []byte(cut), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Analyze(root); err == nil || !strings.Contains(err.Error(), "state.broken") {
		t.Fatalf("Analyze error = %v, want one naming state.broken", err)
	}
}

func TestSnapAndCutRegenerateAMaster(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	write := func(rel, content string) {
		path := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	master := `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">
  <circle cx="12.1" cy="12" r="9.3"/><path d="M8 12.2L11 15L16 9"/>
</svg>
`
	write("state/success.svg", master)
	write("state/pinned.svg", master)
	write("state/pinned.16.svg", `<svg data-hand-cut="true" viewBox="0 0 16 16"><circle cx="8" cy="8" r="6.5"/></svg>`)
	write("security/redacted.svg", master) // exempt from both passes

	snapped, err := Snap(root)
	if err != nil {
		t.Fatal(err)
	}
	if snapped != 2 {
		t.Fatalf("snapped %d masters, want 2", snapped)
	}
	got, _ := os.ReadFile(filepath.Join(root, "state/success.svg"))
	if !strings.Contains(string(got), `<circle cx="12" cy="12" r="9.5"/><path d="M8 12L11 15L16 9"/>`) {
		t.Fatalf("snapped master:\n%s", got)
	}
	if exempt, _ := os.ReadFile(filepath.Join(root, "security/redacted.svg")); string(exempt) != master {
		t.Fatal("an exempt master was snapped")
	}

	report, err := Cut(root)
	if err != nil {
		t.Fatal(err)
	}
	if report.Written != 1 || report.HandKept != 1 || len(report.Skipped) != 1 {
		t.Fatalf("cut report %+v", report)
	}
	cut, _ := os.ReadFile(filepath.Join(root, "state/success.16.svg"))
	want := cutHeader + "\n  " + `<circle cx="8" cy="8" r="6.5"/><path d="M5.5 8L7.5 10L10.5 6"/>` + "\n</svg>\n"
	if string(cut) != want {
		t.Fatalf("cut:\n%s\nwant:\n%s", cut, want)
	}
	if kept, _ := os.ReadFile(filepath.Join(root, "state/pinned.16.svg")); !strings.Contains(string(kept), "data-hand-cut") {
		t.Fatal("a hand cut was overwritten")
	}

	rows, err := Analyze(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 || rows[0].Token != "state.pinned" || rows[1].Token != "state.success" {
		t.Fatalf("audited %+v", rows)
	}
	if rows[1].Class != "round" || rows[1].HandCut || !rows[0].HandCut {
		t.Fatalf("audited %+v", rows)
	}
	var table bytes.Buffer
	PrintAudit(&table, rows)
	if !strings.HasPrefix(table.String(), "cuts: 2   outliers: ") {
		t.Fatalf("audit table:\n%s", table.String())
	}
}
