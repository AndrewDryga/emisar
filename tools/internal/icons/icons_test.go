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

// Short of its operands also covers a command carrying no operand group at all:
// a trailing letter, or a group cut off by the next command instead of by the end
// of the path. Bounding only the operands that get read left those parsing clean,
// and the rewriter then dropped the command from its output without a word.
func TestCommandWithoutACompleteOperandGroupIsAnError(t *testing.T) {
	t.Parallel()
	snap := transform{
		x: halfGrid, y: halfGrid, controlX: quarterGrid, controlY: quarterGrid, radius: halfGrid, dot: halfGrid,
	}
	malformed := []string{
		"M",                  // nothing but a moveto
		"M1 1L",              // a trailing lineto
		"M1 1H",              // a trailing horizontal
		"M1 1A6 6 0 1 0",     // an arc with no endpoint and no following token
		"M1 1L2M3 3",         // a lineto pair interrupted by the next moveto
		"M1 1C1 2 3 4 5M6 6", // a cubic interrupted by the next moveto
		"M1 1L2 2C",          // a trailing cubic after complete operands
	}
	for _, d := range malformed {
		if _, err := parsePath(d); err == nil {
			t.Errorf("parsePath(%q) = nil error, want a malformed-path error", d)
		}
		if _, err := rebuildPath(d, snap); err == nil {
			t.Errorf("rebuildPath(%q) = nil error, want a malformed-path error", d)
		}
	}
	// Negative controls: the supported grammar still parses, including repeated
	// operand groups, the zero-operand closepaths, and a closepath mid-path.
	for _, d := range []string{
		"M2 2H6V6.5Z", "M1 1L2 2 3 3z", "M2 8A6 6 0 1 0 14 8Z",
		"M1 1 2 2 3 3", "M1 1L2 2ZM4 4L5 5Z", "M1 1Q2 2 3 3T4 4S5 5 6 6",
	} {
		if _, err := parsePath(d); err != nil {
			t.Errorf("parsePath(%q): %v", d, err)
		}
		if _, err := rebuildPath(d, snap); err != nil {
			t.Errorf("rebuildPath(%q): %v", d, err)
		}
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

// A master can lose its <svg> wrapper: truncated mid-write, hand-edited, or saved
// as a bare fragment. The body regexp then matches nothing, and both readers that
// index its capture have to name the icon instead of indexing an empty match.
func TestMasterWithoutAnSvgWrapperNamesTheIcon(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "state"), 0o755); err != nil {
		t.Fatal(err)
	}
	// A bare fragment: no wrapper at all.
	if err := os.WriteFile(filepath.Join(root, "state/wrapperless.svg"), []byte("<path d=\"M1 1L2 2\"/>\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Cut(root); err == nil || !strings.Contains(err.Error(), "state/wrapperless") {
		t.Fatalf("Cut error = %v, want one naming state/wrapperless", err)
	}

	// A cut truncated after its opening tag still declares the 16 viewBox, so the
	// auditor reaches it and names it with the dotted token.
	cut := `<svg viewBox="0 0 16 16"><path d="M5.5 8L7.5 10"/>`
	if err := os.WriteFile(filepath.Join(root, "state/wrapperless.16.svg"), []byte(cut), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Analyze(root); err == nil || !strings.Contains(err.Error(), "state.wrapperless") {
		t.Fatalf("Analyze error = %v, want one naming state.wrapperless", err)
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

// A 1px run is crisp at every integer display scale only when its centre line
// sits on a pixel centre (n+0.5); an integer centre splits it across two pixel
// rows at 1x and 3x.
func TestPixelCentre(t *testing.T) {
	t.Parallel()
	cases := []struct{ in, want float64 }{
		{1.83, 1.5}, {14.17, 14.5}, // a frame's two edges grow together
		{2, 1.5}, {14, 14.5}, // a tie breaks away from the centre
		{4.91, 4.5}, {11.08, 11.5}, {10.84, 10.5},
		{7.5, 7.5}, {7.4, 7.5}, // a drawing that moved keeps its axis on a centre
		{7.99, 7.5}, {8.01, 8.5}, // the box centre is no exception: it splits as a tie
	}
	for _, c := range cases {
		if got := pixelCentre(c.in); got != c.want {
			t.Errorf("pixelCentre(%v) = %v, want %v", c.in, got, c.want)
		}
	}
}

// A run centred on the box centre splits across two pixel rows however it
// rounds, so the cutter moves the whole drawing half a pixel off it, on that
// axis only. The test is the old exemption's: the run's scaled position within
// 0.05 of the centre.
func TestMirrorShift(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name          string
		runs          []float64
		centre, scale float64
		want          float64
	}{
		{"a run on the centre", []float64{2.5, 8, 13.5}, 8, 1, 0.5},
		{"a run that scales onto it", []float64{5.5}, 5.4, 0.5, 0.5},
		{"a run beside it", []float64{7.9}, 8, 1, 0},
		{"runs only off the centre", []float64{2.5, 13.5}, 8, 1, 0},
		{"no runs", nil, 8, 1, 0},
	}
	for _, c := range cases {
		if got := mirrorShift(c.runs, c.centre, c.scale); got != c.want {
			t.Errorf("%s: mirrorShift = %v, want %v", c.name, got, c.want)
		}
	}
}

// The cutter lands every stroked axis-aligned run on a pixel centre: a rect is
// mapped by its edges (no lopsided 2..14.5 frame), a vertex lying on a run's
// line moves with it (the arrowhead arm that ends on the sheet's bottom edge),
// and filled shapes and diagonals keep the half grid.
func TestCutPutsAxisRunsOnPixelCentres(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	masters := map[string]string{
		"state/approved":  `<rect x="4" y="4" width="16" height="16" rx="3"/><path class="accent" d="M8 12L10.5 15L16.5 9"/>`,
		"docs/deployment": `<rect x="3.5" y="5" width="11" height="14" rx="2"/><path d="M6.5 9H11.5M6.5 13H10"/><path class="accent" d="M13 16H21M21 16L18 13M21 16L18 19"/>`,
		"action/add":      `<path d="M12 4V20M4 12H20"/>`,
	}
	want := map[string]string{
		"state/approved":  `<rect x="1.5" y="1.5" width="13" height="13" rx="2.5"/><path class="accent" d="M5 8L7 10.5L11.5 5.5"/>`,
		"docs/deployment": `<rect x="1.5" y="3.5" width="8" height="9" rx="1.5"/><path d="M4 5.5H7.5M4 8.5H6.5"/><path class="accent" d="M8.5 10.5H14M14 10.5L12 8.5M14 10.5L12 12.5"/>`,
		"action/add":      `<path d="M7.5 2V13M2 7.5H13"/>`,
	}
	for key, body := range masters {
		path := filepath.Join(root, key+".svg")
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		master := `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">` + "\n  " + body + "\n</svg>\n"
		if err := os.WriteFile(path, []byte(master), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := Cut(root); err != nil {
		t.Fatal(err)
	}
	for key, body := range want {
		got, _ := os.ReadFile(filepath.Join(root, key+".16.svg"))
		if string(got) != cutHeader+"\n  "+body+"\n</svg>\n" {
			t.Errorf("%s cut:\n%s\nwant:\n  %s", key, got, body)
		}
	}
}

// A drawing with a run on the box centre moves half a pixel toward the origin on
// that axis and snaps around the new axis (7.5), so the run is sharp and what
// was symmetric about the box stays symmetric about it. The other axis does not
// move: the arrow's x extent is not a mirror run.
func TestCutMovesAMirrorAxisRunOffTheBoxCentre(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	masters := map[string]string{
		"action/next":    `<path d="M4 12H20M20 12L15 7M20 12L15 17"/>`,
		"action/menu":    `<path d="M4 6H20M4 12H20M4 18H20"/>`,
		"device/desktop": `<rect x="3.5" y="4" width="17" height="12.5" rx="2"/><path d="M8.5 20H15.5M12 16.5V20"/>`,
	}
	want := map[string]string{
		"action/next": `<path d="M2.5 7.5H13.5M13.5 7.5L10 4M13.5 7.5L10 11"/>`,
		// The three bars stay evenly spaced: 3.5, 7.5, 11.5.
		"action/menu": `<path d="M2.5 3.5H13.5M2.5 7.5H13.5M2.5 11.5H13.5"/>`,
		// The frame's two edges re-lay as a pair about 7.5, and the stem sits in the middle.
		"device/desktop": `<rect x="1.5" y="2.5" width="12" height="9" rx="1.5"/><path d="M5 13.5H10M7.5 11.5V13.5"/>`,
	}
	for key, body := range masters {
		path := filepath.Join(root, key+".svg")
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		master := `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">` + "\n  " + body + "\n</svg>\n"
		if err := os.WriteFile(path, []byte(master), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := Cut(root); err != nil {
		t.Fatal(err)
	}
	for key, body := range want {
		got, _ := os.ReadFile(filepath.Join(root, key+".16.svg"))
		if string(got) != cutHeader+"\n  "+body+"\n</svg>\n" {
			t.Errorf("%s cut:\n%s\nwant:\n  %s", key, got, body)
		}
	}
}
