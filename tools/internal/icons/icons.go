// Package icons normalizes the first-party icon masters under
// portal/apps/emisar_web/priv/icons: it snaps the 24-grid regulars to the half
// grid, cuts the native 16-grid compacts from them, and audits the cuts'
// optical size. The design rules live in
// portal/.agent/kb/rules/design-semantic-icon-system.md; this is their tooling.
package icons

import (
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// Every 16-grid cut opens the same way; the body is the only thing that varies.
const cutHeader = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">`

// The cutter scales 24 → 16, and its stroke rides the same scale corrected to
// the 1.5 rendered weight.
const (
	cutScale     = 2.0 / 3.0
	strokeFactor = 1.5 / 1.55
)

// Ink targets (stroke included) per optical archetype, and the growth cap that
// keeps small-drawn objects from violent rescaling.
var cutTargets = map[string]float64{"round": 14, "square": 13.5, "wide": 14}

const (
	maxGrow   = 1.16
	maxShrink = 0.9
)

// Operators, arrows, carets, and the balanced decision pair keep their
// deliberate glyph sizes — every professional set draws these smaller than
// containers (the Heroicons × is 47% of its box).
var keepGlyphSize = set(
	"action/add", "action/approve", "action/close",
	"action/disclose", "action/download", "action/execute", "action/menu",
	"action/move_down", "action/move_up", "action/next", "action/publish",
	"action/refresh", "action/remove", "action/search", "action/select",
	"action/sign_out", "action/sync", "action/undo", "action/upload",
	"breadcrumb/separator", "diagram/flow_down", "diagram/flow_right",
	"state/cancelled", "state/included", "state/not_included",
)

// Masked, pixel-tuned, transformed, or official artwork: no native cut —
// these render through the zoomed 24-grid projection.
var noCut = set(
	"action/retry", "communication/prompt_suppressed", "security/redacted",
	"state/magic_link_sent", "state/offline", "state/revoked", "state/selected",
	"trust/untrusted", "action/replay",
	"infrastructure/kubernetes", "infrastructure/nomad",
)

// The snapper's exemptions are the cutter's plus one more pixel-tuned master.
var noSnap = set(append(keys(noCut), "action/clear_filters")...)

var (
	svgBody       = regexp.MustCompile(`(?s)<svg[^>]*>(.*)</svg>`)
	unsnappable   = regexp.MustCompile(`<defs>|transform=`)
	uncuttable    = regexp.MustCompile(`<defs>|transform=|shape-rendering="crispEdges"`)
	handCutMarker = "data-hand-cut"
)

// Snap rounds the 24-grid regular masters onto the half grid in place and
// reports how many files changed. Control points snap to the quarter grid.
// Masked, pixel-tuned, transformed, and official-artwork masters are exempt —
// their sub-quarter optical nudges are deliberate.
func Snap(root string) (int, error) {
	snap := transform{
		x: halfGrid, y: halfGrid,
		controlX: quarterGrid, controlY: quarterGrid,
		radius: halfGrid,
		dot:    func(v float64) float64 { return math.Max(1, quarterGrid(v)) },
	}
	written := 0
	err := eachMaster(root, func(key, path string) error {
		if noSnap[key] {
			return nil
		}
		src, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if unsnappable.Match(src) {
			return nil
		}
		out := transformBody(string(src), snap)
		if out == string(src) {
			return nil
		}
		written++
		return os.WriteFile(path, []byte(out), 0o644)
	})
	return written, err
}

// CutReport counts what one cutter run did.
type CutReport struct {
	Written  int
	HandKept int
	Skipped  []string
}

// Cut derives the native 16-grid compact from every 24-grid regular: scale 2/3,
// optical normalization to the archetype target, half-grid snap. A cut that
// declares data-hand-cut is never overwritten — the escape hatch for cuts tuned
// by hand.
func Cut(root string) (CutReport, error) {
	report := CutReport{}
	scaleDown := func(v float64) float64 { return v * cutScale }
	stroke := func(v float64) float64 { return v * cutScale * strokeFactor }
	err := eachMaster(root, func(key, path string) error {
		if noCut[key] {
			report.Skipped = append(report.Skipped, key)
			return nil
		}
		cutPath := strings.TrimSuffix(path, ".svg") + ".16.svg"
		if existing, err := os.ReadFile(cutPath); err == nil && strings.Contains(string(existing), handCutMarker) {
			report.HandKept++
			return nil
		}
		src, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if uncuttable.Match(src) {
			report.Skipped = append(report.Skipped, key+" (defs/transform)")
			return nil
		}
		body := strings.TrimSpace(svgBody.FindStringSubmatch(string(src))[1])

		// Pass 1: scale 24 → 16 with no snap, so the optical pass measures truth.
		raw := transformBody(body, transform{
			x: scaleDown, y: scaleDown, controlX: scaleDown, controlY: scaleDown,
			radius: scaleDown, dot: scaleDown, strokeWidth: stroke,
		})

		// Pass 2: optical normalization — archetype target with capped growth,
		// recentered on the box.
		scale, cx, cy := 1.0, 8.0, 8.0
		points, arcRatio := bodyPoints(raw)
		if len(points) > 0 {
			b := bounds(points)
			cx, cy = b.cx, b.cy
			if !keepGlyphSize[key] {
				major := math.Max(b.w, b.h) + 1
				target := cutTargets[classify(b, arcRatio, true)]
				scale = math.Min(maxGrow, math.Max(maxShrink, target/major))
			}
		}

		// Pass 3: apply about the drawing's own centre, land it on the box
		// centre, snap to the crisp grid. Each product is rounded before the
		// recentering add so the compiler cannot fuse the two.
		px := func(v float64) float64 { return halfGrid(float64((v-cx)*scale) + 8) }
		py := func(v float64) float64 { return halfGrid(float64((v-cy)*scale) + 8) }
		pr := func(v float64) float64 { return halfGrid(v * scale) }
		prDot := func(v float64) float64 { return math.Max(0.75, quarterGrid(v*scale)) }
		out := transformBody(raw, transform{
			x: px, y: py, controlX: px, controlY: py,
			radius: pr, dot: prDot, strokeWidth: stroke,
		})

		report.Written++
		return os.WriteFile(cutPath, []byte(cutHeader+"\n  "+out+"\n</svg>\n"), 0o644)
	})
	return report, err
}

// classify names the optical archetype of a drawing's bounds. The cutter guards
// a flat drawing's zero height; the auditor reports it as wide.
func classify(b box, arcRatio float64, guardFlat bool) string {
	h := b.h
	if guardFlat {
		h = math.Max(h, 0.001)
	}
	aspect := b.w / h
	if aspect >= 1.45 || aspect <= 0.62 {
		return "wide"
	}
	if arcRatio > 0.55 && math.Abs(aspect-1) < 0.2 {
		return "round"
	}
	return "square"
}

// Audit targets, stroke ink included (1px → ±0.5). Round forms overshoot
// squares slightly so everything FEELS equal; wide forms cap width and give
// height back.
var auditTargets = map[string]float64{"round": 14.0, "square": 13.5, "wide": 14.5}

// Row is one audited 16-grid cut: true geometry bounds (stroke included), shape
// class, and the deviation from that class's target size.
type Row struct {
	Token   string
	Class   string
	Major   float64
	W, H    float64
	DX, DY  float64
	Scale   float64
	HandCut bool
}

// Analyze measures every native 16-grid cut.
func Analyze(root string) ([]Row, error) {
	var rows []Row
	err := eachFile(root, func(ns, name, path string) error {
		if !strings.HasSuffix(name, ".16.svg") {
			return nil
		}
		src, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if !strings.Contains(string(src), `viewBox="0 0 16 16"`) {
			return nil
		}
		points, arcRatio := bodyPoints(svgBody.FindStringSubmatch(string(src))[1])
		if len(points) == 0 {
			return nil
		}
		b := bounds(points)
		inkW, inkH := b.w+1, b.h+1
		class := classify(b, arcRatio, false)
		major := math.Max(inkW, inkH)
		rows = append(rows, Row{
			Token:   ns + "." + strings.TrimSuffix(name, ".16.svg"),
			Class:   class,
			Major:   toFixed(major, 2),
			W:       toFixed(inkW, 2),
			H:       toFixed(inkH, 2),
			DX:      toFixed(b.cx-8, 2),
			DY:      toFixed(b.cy-8, 2),
			Scale:   toFixed(auditTargets[class]/major, 3),
			HandCut: strings.Contains(string(src), handCutMarker),
		})
		return nil
	})
	return rows, err
}

// Outliers are the cuts more than 4% off their target size or more than 0.35u
// off centre, smallest scale first.
func Outliers(rows []Row) []Row {
	var off []Row
	for _, r := range rows {
		if math.Abs(1-r.Scale) > 0.04 || math.Abs(r.DX) > 0.35 || math.Abs(r.DY) > 0.35 {
			off = append(off, r)
		}
	}
	sort.SliceStable(off, func(i, j int) bool { return off[i].Scale < off[j].Scale })
	return off
}

// PrintAudit writes the outlier table.
func PrintAudit(w io.Writer, rows []Row) {
	off := Outliers(rows)
	fmt.Fprintf(w, "cuts: %d   outliers: %d\n", len(rows), len(off))
	fmt.Fprintf(w, "%-36s %-7s %-14s %-12s %s\n", "token", "cls", "w×h", "off-center", "scale→")
	for _, r := range off {
		size := jsString(r.W) + "×" + jsString(r.H)
		centre := jsString(r.DX) + "," + jsString(r.DY)
		fmt.Fprintf(w, "%-36s %-7s %-14s %-12s %s\n", r.Token, r.Class, size, centre, jsString(r.Scale))
	}
}

// eachMaster visits every 24-grid regular master (not the .16 cuts) in
// namespace order, keyed "namespace/name".
func eachMaster(root string, visit func(key, path string) error) error {
	return eachFile(root, func(ns, name, path string) error {
		if !strings.HasSuffix(name, ".svg") || strings.HasSuffix(name, ".16.svg") {
			return nil
		}
		return visit(ns+"/"+strings.TrimSuffix(name, ".svg"), path)
	})
}

func eachFile(root string, visit func(ns, name, path string) error) error {
	namespaces, err := os.ReadDir(root)
	if err != nil {
		return err
	}
	for _, namespace := range namespaces {
		if !namespace.IsDir() {
			continue
		}
		files, err := os.ReadDir(filepath.Join(root, namespace.Name()))
		if err != nil {
			return err
		}
		for _, file := range files {
			if err := visit(namespace.Name(), file.Name(), filepath.Join(root, namespace.Name(), file.Name())); err != nil {
				return err
			}
		}
	}
	return nil
}

func set(keys ...string) map[string]bool {
	s := make(map[string]bool, len(keys))
	for _, k := range keys {
		s[k] = true
	}
	return s
}

func keys(s map[string]bool) []string {
	out := make([]string, 0, len(s))
	for k := range s {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
