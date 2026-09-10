package icons

import (
	"regexp"
	"strconv"
	"strings"
)

// Path rewriting for the two normalizers. Both walk a path's tokens,
// absolutize relative commands, and pass every coordinate through a transform;
// snapping is just a transform that rounds.

// A transform is the set of coordinate maps one pass applies to an element:
// endpoints, curve control points, radii and sizes, the radius of a filled dot,
// and (for the cutter) the stroke width. Every value is formatted on the way
// out, so a transform never sees a formatted number twice.
type transform struct {
	x, y        func(float64) float64
	controlX    func(float64) float64
	controlY    func(float64) float64
	radius      func(float64) float64
	dot         func(float64) float64
	strokeWidth func(float64) float64 // nil leaves stroke-width alone
}

var (
	pathTokens = regexp.MustCompile(`[MmLlHhVvCcSsQqTtAaZz]|-?\d*\.?\d+(?:e-?\d+)?`)
	element    = regexp.MustCompile(`<(path|circle|rect|ellipse|line)\b[^>]*/?>`)
	dAttribute = regexp.MustCompile(`\bd="([^"]+)"`)
	xAttribute = regexp.MustCompile(`\b(cx|x|x1|x2)="(-?\d*\.?\d+)"`)
	yAttribute = regexp.MustCompile(`\b(cy|y|y1|y2)="(-?\d*\.?\d+)"`)
	rAttribute = regexp.MustCompile(`\br="(-?\d*\.?\d+)"`)
	// \bwidth also matches inside stroke-width; the cutter's stroke-width rule
	// then rescales that value. The committed cuts carry that double pass.
	sizeAttribute   = regexp.MustCompile(`\b(rx|ry|width|height)="(-?\d*\.?\d+)"`)
	strokeAttribute = regexp.MustCompile(`\bstroke-width="(-?\d*\.?\d+)"`)
	dotMarker       = regexp.MustCompile(`fill="currentColor"|accent-fill|warn-fill|danger-fill`)
)

// rebuildPath absolutizes d and maps every coordinate through t. A relative
// moveto that opens the path is absolute by definition; every later pair after
// a moveto is an implicit lineto.
func rebuildPath(d string, t transform) string {
	tokens := pathTokens.FindAllString(d, -1)
	var out []string
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
		rel := cmd == strings.ToLower(cmd) && cmd != "z" && cmd != "Z"
		switch strings.ToUpper(cmd) {
		case "M":
			first := true
			for more() {
				px, py := read(), read()
				if rel && !(first && len(out) == 0) {
					x, y = x+px, y+py
				} else {
					x, y = px, py
				}
				command := "L"
				if first {
					command = "M"
				}
				out = append(out, command+format(t.x(x))+" "+format(t.y(y)))
				if first {
					sx, sy, first = x, y, false
				}
			}
		case "L":
			for more() {
				px, py := read(), read()
				x, y = absolute(rel, x, px), absolute(rel, y, py)
				out = append(out, "L"+format(t.x(x))+" "+format(t.y(y)))
			}
		case "H":
			for more() {
				x = absolute(rel, x, read())
				out = append(out, "H"+format(t.x(x)))
			}
		case "V":
			for more() {
				y = absolute(rel, y, read())
				out = append(out, "V"+format(t.y(y)))
			}
		case "C":
			for more() {
				c := [6]float64{read(), read(), read(), read(), read(), read()}
				a := [6]float64{absolute(rel, x, c[0]), absolute(rel, y, c[1]), absolute(rel, x, c[2]), absolute(rel, y, c[3]), absolute(rel, x, c[4]), absolute(rel, y, c[5])}
				x, y = a[4], a[5]
				out = append(out, "C"+format(t.controlX(a[0]))+" "+format(t.controlY(a[1]))+" "+format(t.controlX(a[2]))+" "+format(t.controlY(a[3]))+" "+format(t.x(a[4]))+" "+format(t.y(a[5])))
			}
		case "S":
			for more() {
				c := [4]float64{read(), read(), read(), read()}
				a := [4]float64{absolute(rel, x, c[0]), absolute(rel, y, c[1]), absolute(rel, x, c[2]), absolute(rel, y, c[3])}
				x, y = a[2], a[3]
				out = append(out, "S"+format(t.controlX(a[0]))+" "+format(t.controlY(a[1]))+" "+format(t.x(a[2]))+" "+format(t.y(a[3])))
			}
		case "Q":
			for more() {
				c := [4]float64{read(), read(), read(), read()}
				a := [4]float64{absolute(rel, x, c[0]), absolute(rel, y, c[1]), absolute(rel, x, c[2]), absolute(rel, y, c[3])}
				x, y = a[2], a[3]
				out = append(out, "Q"+format(t.controlX(a[0]))+" "+format(t.controlY(a[1]))+" "+format(t.x(a[2]))+" "+format(t.y(a[3])))
			}
		case "T":
			for more() {
				px, py := read(), read()
				x, y = absolute(rel, x, px), absolute(rel, y, py)
				out = append(out, "T"+format(t.x(x))+" "+format(t.y(y)))
			}
		case "A":
			for more() {
				rx, ry, rot, large, sweep := read(), read(), read(), read(), read()
				px, py := read(), read()
				x, y = absolute(rel, x, px), absolute(rel, y, py)
				out = append(out, "A"+format(t.radius(rx))+" "+format(t.radius(ry))+" "+format(rot)+" "+jsString(large)+" "+jsString(sweep)+" "+format(t.x(x))+" "+format(t.y(y)))
			}
		case "Z":
			x, y = sx, sy
			out = append(out, "Z")
		}
	}
	return strings.Join(out, "")
}

func absolute(rel bool, current, v float64) float64 {
	if rel {
		return current + v
	}
	return v
}

// transformBody rewrites every drawable element in an svg body through t.
func transformBody(body string, t transform) string {
	var out strings.Builder
	last := 0
	for _, loc := range element.FindAllStringSubmatchIndex(body, -1) {
		start, end := loc[0], loc[1]
		if closing := "</" + body[loc[2]:loc[3]] + ">"; strings.HasPrefix(body[end:], closing) {
			end += len(closing)
		}
		out.WriteString(body[last:start])
		out.WriteString(rewriteElement(body[start:end], t))
		last = end
	}
	out.WriteString(body[last:])
	return out.String()
}

func rewriteElement(tag string, t transform) string {
	dot := dotMarker.MatchString(tag)
	tag = replace(dAttribute, tag, func(groups []string) string {
		return `d="` + rebuildPath(groups[1], t) + `"`
	})
	tag = replace(xAttribute, tag, func(groups []string) string {
		return groups[1] + `="` + format(t.x(number(groups[2]))) + `"`
	})
	tag = replace(yAttribute, tag, func(groups []string) string {
		return groups[1] + `="` + format(t.y(number(groups[2]))) + `"`
	})
	tag = replace(rAttribute, tag, func(groups []string) string {
		radius := t.radius
		if dot {
			radius = t.dot
		}
		return `r="` + format(radius(number(groups[1]))) + `"`
	})
	tag = replace(sizeAttribute, tag, func(groups []string) string {
		return groups[1] + `="` + format(t.radius(number(groups[2]))) + `"`
	})
	if t.strokeWidth != nil {
		tag = replace(strokeAttribute, tag, func(groups []string) string {
			return `stroke-width="` + format(t.strokeWidth(number(groups[1]))) + `"`
		})
	}
	return tag
}

func number(s string) float64 {
	v, _ := strconv.ParseFloat(s, 64)
	return v
}

// replace is ReplaceAllStringFunc with the submatches in hand.
func replace(re *regexp.Regexp, s string, with func(groups []string) string) string {
	var out strings.Builder
	last := 0
	for _, loc := range re.FindAllStringSubmatchIndex(s, -1) {
		groups := make([]string, 0, len(loc)/2)
		for g := 0; g < len(loc); g += 2 {
			if loc[g] < 0 {
				groups = append(groups, "")
				continue
			}
			groups = append(groups, s[loc[g]:loc[g+1]])
		}
		out.WriteString(s[last:loc[0]])
		out.WriteString(with(groups))
		last = loc[1]
	}
	out.WriteString(s[last:])
	return out.String()
}
