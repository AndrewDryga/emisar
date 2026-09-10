package icons

import (
	"math"
	"regexp"
	"strconv"
	"strings"
)

// Geometry sampling for the optical passes: every drawable element in an svg
// body becomes a cloud of points whose bounds decide the archetype, the
// optical scale, and the recentering. The cutter emits absolute-only commands,
// so the sampler parses exactly that set.

type segment struct {
	kind               byte
	x0, y0, x, y       float64
	c1x, c1y, c2x, c2y float64 // cubic controls
	cx, cy             float64 // quadratic control
	rx, ry, rot        float64 // arc
	large, sweep       float64
}

var (
	absoluteTokens = regexp.MustCompile(`(?i)[MLHVCSQTAZ]|-?\d*\.?\d+(?:e-?\d+)?`)
	letter         = regexp.MustCompile(`[A-Za-z]`)
	pathElement    = regexp.MustCompile(`<path\b[^>]*\bd="([^"]+)"[^>]*>`)
	circleElement  = regexp.MustCompile(`<circle\b[^>]*>`)
	rectElement    = regexp.MustCompile(`<rect\b[^>]*>`)
)

// parsePath reads absolute commands into segments. Implicit linetos after a
// moveto record the subpath start as their origin, which is what the sampler
// has always measured.
func parsePath(d string) []segment {
	tokens := absoluteTokens.FindAllString(d, -1)
	var segments []segment
	i, x, y, sx, sy := 0, 0.0, 0.0, 0.0, 0.0
	read := func() float64 {
		v, _ := strconv.ParseFloat(tokens[i], 64)
		i++
		return v
	}
	more := func() bool { return i < len(tokens) && !letter.MatchString(tokens[i]) }
	for i < len(tokens) {
		cmd := tokens[i]
		i++
		switch cmd {
		case "M":
			first := true
			for more() {
				x, y = read(), read()
				if first {
					sx, sy, first = x, y, false
				} else {
					segments = append(segments, segment{kind: 'L', x0: sx, y0: sy, x: x, y: y})
				}
				segments = append(segments, segment{kind: 'M', x: x, y: y})
			}
		case "L":
			for more() {
				nx, ny := read(), read()
				segments = append(segments, segment{kind: 'L', x0: x, y0: y, x: nx, y: ny})
				x, y = nx, ny
			}
		case "H":
			for more() {
				nx := read()
				segments = append(segments, segment{kind: 'L', x0: x, y0: y, x: nx, y: y})
				x = nx
			}
		case "V":
			for more() {
				ny := read()
				segments = append(segments, segment{kind: 'L', x0: x, y0: y, x: x, y: ny})
				y = ny
			}
		case "C":
			for more() {
				seg := segment{kind: 'C', x0: x, y0: y}
				seg.c1x, seg.c1y, seg.c2x, seg.c2y, seg.x, seg.y = read(), read(), read(), read(), read(), read()
				segments = append(segments, seg)
				x, y = seg.x, seg.y
			}
		case "S":
			for more() {
				seg := segment{kind: 'C', x0: x, y0: y, c1x: x, c1y: y}
				seg.c2x, seg.c2y, seg.x, seg.y = read(), read(), read(), read()
				segments = append(segments, seg)
				x, y = seg.x, seg.y
			}
		case "Q":
			for more() {
				seg := segment{kind: 'Q', x0: x, y0: y}
				seg.cx, seg.cy, seg.x, seg.y = read(), read(), read(), read()
				segments = append(segments, seg)
				x, y = seg.x, seg.y
			}
		case "T":
			for more() {
				nx, ny := read(), read()
				segments = append(segments, segment{kind: 'L', x0: x, y0: y, x: nx, y: ny})
				x, y = nx, ny
			}
		case "A":
			for more() {
				seg := segment{kind: 'A', x0: x, y0: y}
				seg.rx, seg.ry, seg.rot, seg.large, seg.sweep, seg.x, seg.y = read(), read(), read(), read(), read(), read(), read()
				segments = append(segments, seg)
				x, y = seg.x, seg.y
			}
		case "Z", "z":
			segments = append(segments, segment{kind: 'L', x0: x, y0: y, x: sx, y: sy})
			x, y = sx, sy
		}
	}
	return segments
}

type point [2]float64

// sampleArc follows the endpoint parameterization (SVG appendix B.2.4; no
// rotation in this icon set). Products are rounded before every addition so
// the arm64 compiler cannot fuse them and land a bound a bit away from what
// the JavaScript measured.
func sampleArc(seg segment, points []point) []point {
	x0, y0, x, y := seg.x0, seg.y0, seg.x, seg.y
	rx, ry := seg.rx, seg.ry
	if rx == 0 || ry == 0 {
		return append(points, point{x, y})
	}
	rx, ry = math.Abs(rx), math.Abs(ry)
	dx, dy := (x0-x)/2, (y0-y)/2
	l := float64((dx*dx)/(rx*rx)) + float64((dy*dy)/(ry*ry))
	if l > 1 {
		rx *= math.Sqrt(l)
		ry *= math.Sqrt(l)
	}
	sign := -1.0
	if seg.large != seg.sweep {
		sign = 1
	}
	num := float64(float64(rx*rx*ry*ry)-float64(rx*rx*dy*dy)) - float64(ry*ry*dx*dx)
	den := float64(rx*rx*dy*dy) + float64(ry*ry*dx*dx)
	co := sign * math.Sqrt(math.Max(0, num/den))
	cx := float64(co*(rx*dy)/ry) + (x0+x)/2
	cy := float64(co*(-ry*dx)/rx) + (y0+y)/2
	a1 := math.Atan2((y0-cy)/ry, (x0-cx)/rx)
	da := math.Atan2((y-cy)/ry, (x-cx)/rx) - a1
	if seg.sweep == 0 && da > 0 {
		da -= 2 * math.Pi
	}
	if seg.sweep != 0 && da < 0 {
		da += 2 * math.Pi
	}
	for t := 0.0; t <= 1.0001; t += 0.04 {
		a := a1 + float64(da*t)
		points = append(points, point{cx + float64(rx*math.Cos(a)), cy + float64(ry*math.Sin(a))})
	}
	return points
}

func sample(segments []segment) []point {
	var points []point
	for _, seg := range segments {
		switch seg.kind {
		case 'M':
			points = append(points, point{seg.x, seg.y})
		case 'L':
			points = append(points, point{seg.x0, seg.y0}, point{seg.x, seg.y})
		case 'C':
			for t := 0.0; t <= 1.0001; t += 0.05 {
				u := 1 - t
				points = append(points, point{
					float64(float64(float64(u*u*u*seg.x0)+float64(3*u*u*t*seg.c1x))+float64(3*u*t*t*seg.c2x)) + float64(t*t*t*seg.x),
					float64(float64(float64(u*u*u*seg.y0)+float64(3*u*u*t*seg.c1y))+float64(3*u*t*t*seg.c2y)) + float64(t*t*t*seg.y),
				})
			}
		case 'Q':
			for t := 0.0; t <= 1.0001; t += 0.05 {
				u := 1 - t
				points = append(points, point{
					float64(float64(u*u*seg.x0)+float64(2*u*t*seg.cx)) + float64(t*t*seg.x),
					float64(float64(u*u*seg.y0)+float64(2*u*t*seg.cy)) + float64(t*t*seg.y),
				})
			}
		case 'A':
			points = sampleArc(seg, points)
		}
	}
	return points
}

// bodyPoints samples every path, circle, and rect in an svg body, and reports
// how much of the drawing is curved — the round/square archetype signal.
func bodyPoints(body string) (points []point, arcRatio float64) {
	arcish, total := 0, 0
	for _, m := range pathElement.FindAllStringSubmatch(body, -1) {
		segments := parsePath(m[1])
		for _, s := range segments {
			total++
			if s.kind == 'A' || s.kind == 'C' {
				arcish++
			}
		}
		points = append(points, sample(segments)...)
	}
	for _, m := range circleElement.FindAllString(body, -1) {
		cx, cy, r := attribute(m, "cx"), attribute(m, "cy"), attribute(m, "r")
		total++
		arcish++
		if r >= 4 {
			arcish += 3
		}
		for a := 0.0; a < 6.3; a += 0.2 {
			points = append(points, point{cx + float64(r*math.Cos(a)), cy + float64(r*math.Sin(a))})
		}
	}
	for _, m := range rectElement.FindAllString(body, -1) {
		x, y, w, h := attribute(m, "x"), attribute(m, "y"), attribute(m, "width"), attribute(m, "height")
		total++
		points = append(points, point{x, y}, point{x + w, y}, point{x, y + h}, point{x + w, y + h})
	}
	if total > 0 {
		arcRatio = float64(arcish) / float64(total)
	}
	return points, arcRatio
}

// attribute reads a numeric attribute off one element's tag, 0 when absent.
func attribute(tag, name string) float64 {
	m := regexp.MustCompile(`\b` + name + `="([^"]+)"`).FindStringSubmatch(tag)
	if m == nil {
		return 0
	}
	v, _ := strconv.ParseFloat(strings.TrimSpace(m[1]), 64)
	return v
}

type box struct {
	minX, minY, maxX, maxY, w, h, cx, cy float64
}

func bounds(points []point) box {
	b := box{minX: math.Inf(1), minY: math.Inf(1), maxX: math.Inf(-1), maxY: math.Inf(-1)}
	// Plain comparisons, not math.Min/Max: a degenerate arc samples NaN, and a
	// comparison skips it where math.Min would poison every later bound.
	for _, p := range points {
		if p[0] < b.minX {
			b.minX = p[0]
		}
		if p[0] > b.maxX {
			b.maxX = p[0]
		}
		if p[1] < b.minY {
			b.minY = p[1]
		}
		if p[1] > b.maxY {
			b.maxY = p[1]
		}
	}
	b.w, b.h = b.maxX-b.minX, b.maxY-b.minY
	b.cx, b.cy = (b.minX+b.maxX)/2, (b.minY+b.maxY)/2
	return b
}
