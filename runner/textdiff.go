package main

import (
	"fmt"
	"strings"
)

// A line-oriented diff and unified-hunk renderer, used by `pack diff` to show
// an operator the changed lines of a pack upgrade. It knows nothing about
// packs — text in, unified diff out.
//
// Hand-rolled on purpose: the Go standard library exports no diff package, and
// a new dependency on the runner is new attack surface in every self-hoster's
// supply chain (see AGENTS.md). Shelling out to git or diff(1) is not an option
// either — the runner must not need a host binary for a core verb.

// diffKind is one line's role in an edit script.
type diffKind int

const (
	diffEqual diffKind = iota
	diffDelete
	diffInsert
)

// diffLine is one line of an edit script.
type diffLine struct {
	kind diffKind
	text string
}

// diffContext is how many unchanged lines surround each hunk — git's default.
const diffContext = 3

// maxDiffCells bounds the LCS table. The largest script in the pack catalog is
// under a thousand lines, so a 2000x2000 pair fits with room to spare at 16 MB
// of transient int32s. A larger pair renders as a whole-file replacement rather
// than sizing an allocation from input: packs.Fetch admits files up to 8 MiB,
// and squaring that would be tens of gigabytes.
const maxDiffCells = 4_000_000

// splitLines splits file content into lines, dropping the trailing newline so
// "a\nb\n" is two lines rather than three. Content differing ONLY in its
// trailing newline yields identical lines here; the caller compares raw bytes
// to catch that rather than have every ordinary diff carry a phantom last line.
func splitLines(data []byte) []string {
	if len(data) == 0 {
		return nil
	}
	return strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
}

// diffLines returns the edit script that turns a into b.
func diffLines(a, b []string) []diffLine {
	// A real edit touches a few lines of a long file, so trimming the shared
	// head and tail keeps the table proportional to what actually changed.
	prefix := 0
	for prefix < len(a) && prefix < len(b) && a[prefix] == b[prefix] {
		prefix++
	}
	suffix := 0
	for suffix < len(a)-prefix && suffix < len(b)-prefix &&
		a[len(a)-1-suffix] == b[len(b)-1-suffix] {
		suffix++
	}

	out := make([]diffLine, 0, len(a)+len(b))
	for _, line := range a[:prefix] {
		out = append(out, diffLine{diffEqual, line})
	}
	out = append(out, diffMiddle(a[prefix:len(a)-suffix], b[prefix:len(b)-suffix])...)
	for _, line := range a[len(a)-suffix:] {
		out = append(out, diffLine{diffEqual, line})
	}
	return out
}

func diffMiddle(a, b []string) []diffLine {
	if len(a) == 0 && len(b) == 0 {
		return nil
	}
	if len(a) == 0 || len(b) == 0 || len(a)*len(b) > maxDiffCells {
		out := make([]diffLine, 0, len(a)+len(b))
		for _, line := range a {
			out = append(out, diffLine{diffDelete, line})
		}
		for _, line := range b {
			out = append(out, diffLine{diffInsert, line})
		}
		return out
	}

	// table[i*w+j] is the longest common subsequence of a[i:] and b[j:], so the
	// walk below can pick the better branch by looking one step ahead.
	w := len(b) + 1
	table := make([]int32, (len(a)+1)*w)
	for i := len(a) - 1; i >= 0; i-- {
		for j := len(b) - 1; j >= 0; j-- {
			switch {
			case a[i] == b[j]:
				table[i*w+j] = table[(i+1)*w+j+1] + 1
			case table[(i+1)*w+j] >= table[i*w+j+1]:
				table[i*w+j] = table[(i+1)*w+j]
			default:
				table[i*w+j] = table[i*w+j+1]
			}
		}
	}

	out := make([]diffLine, 0, len(a)+len(b))
	i, j := 0, 0
	for i < len(a) && j < len(b) {
		switch {
		case a[i] == b[j]:
			out = append(out, diffLine{diffEqual, a[i]})
			i, j = i+1, j+1
		// Ties favor the deletion so a replaced line reads "-old" then "+new",
		// the order every diff reader expects.
		case table[(i+1)*w+j] >= table[i*w+j+1]:
			out = append(out, diffLine{diffDelete, a[i]})
			i++
		default:
			out = append(out, diffLine{diffInsert, b[j]})
			j++
		}
	}
	for ; i < len(a); i++ {
		out = append(out, diffLine{diffDelete, a[i]})
	}
	for ; j < len(b); j++ {
		out = append(out, diffLine{diffInsert, b[j]})
	}
	return out
}

// countEdits returns how many lines the script inserts and deletes.
func countEdits(script []diffLine) (insertions, deletions int) {
	for _, l := range script {
		switch l.kind {
		case diffInsert:
			insertions++
		case diffDelete:
			deletions++
		}
	}
	return insertions, deletions
}

// unifiedDiff renders the script as unified hunks with `context` lines around
// each change, or "" when nothing changed.
func unifiedDiff(script []diffLine, context int) string {
	// Running 0-based line counts per side, so each header can say where its
	// hunk starts in the old file and in the new one.
	oldNo := make([]int, len(script)+1)
	newNo := make([]int, len(script)+1)
	o, n := 0, 0
	for i, l := range script {
		oldNo[i], newNo[i] = o, n
		if l.kind != diffInsert {
			o++
		}
		if l.kind != diffDelete {
			n++
		}
	}
	oldNo[len(script)], newNo[len(script)] = o, n

	// Changes closer together than twice the context share a hunk; rendering
	// them apart would print the same lines twice as both trailing and leading
	// context.
	var groups [][2]int
	for i, l := range script {
		if l.kind == diffEqual {
			continue
		}
		if len(groups) > 0 && i-groups[len(groups)-1][1]-1 <= 2*context {
			groups[len(groups)-1][1] = i
			continue
		}
		groups = append(groups, [2]int{i, i})
	}

	var b strings.Builder
	for _, g := range groups {
		start := max(0, g[0]-context)
		end := min(len(script), g[1]+1+context)
		fmt.Fprintf(&b, "@@ -%s +%s @@\n",
			hunkRange(oldNo[start], oldNo[end]-oldNo[start]),
			hunkRange(newNo[start], newNo[end]-newNo[start]))
		for _, l := range script[start:end] {
			switch l.kind {
			case diffInsert:
				b.WriteByte('+')
			case diffDelete:
				b.WriteByte('-')
			default:
				b.WriteByte(' ')
			}
			b.WriteString(l.text)
			b.WriteByte('\n')
		}
	}
	return b.String()
}

// hunkRange formats one side of an @@ header from a 0-based start and a line
// count. An empty range is numbered by the line BEFORE it, so an insertion at
// the top of a file reads "-0,0" — the same convention git uses.
func hunkRange(start, count int) string {
	switch count {
	case 0:
		return fmt.Sprintf("%d,0", start)
	case 1:
		return fmt.Sprintf("%d", start+1)
	default:
		return fmt.Sprintf("%d,%d", start+1, count)
	}
}
