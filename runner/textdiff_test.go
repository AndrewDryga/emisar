package main

import (
	"strings"
	"testing"
)

func TestSplitLines(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want []string
	}{
		{"empty", "", nil},
		{"one line with newline", "a\n", []string{"a"}},
		{"one line without newline", "a", []string{"a"}},
		{"two lines", "a\nb\n", []string{"a", "b"}},
		// A blank final line survives: "a\n\n" is two lines, the second empty.
		{"trailing blank line", "a\n\n", []string{"a", ""}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := splitLines([]byte(tt.in))
			if len(got) != len(tt.want) {
				t.Fatalf("splitLines(%q) = %q, want %q", tt.in, got, tt.want)
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Fatalf("splitLines(%q) = %q, want %q", tt.in, got, tt.want)
				}
			}
		})
	}
}

// Unified output is the contract `pack diff` prints, so the cases below assert
// the rendered text rather than the intermediate edit script.
func TestUnifiedDiff(t *testing.T) {
	tests := []struct {
		name string
		a    string
		b    string
		want string
	}{
		{
			name: "identical input produces no hunks",
			a:    "a\nb\nc\n",
			b:    "a\nb\nc\n",
			want: "",
		},
		{
			name: "replacement shows the deletion before the insertion",
			a:    "a\nb\nc\n",
			b:    "a\nB\nc\n",
			want: "@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n",
		},
		{
			name: "pure insertion in the middle",
			a:    "a\nb\n",
			b:    "a\nx\nb\n",
			want: "@@ -1,2 +1,3 @@\n a\n+x\n b\n",
		},
		{
			name: "pure deletion in the middle",
			a:    "a\nx\nb\n",
			b:    "a\nb\n",
			want: "@@ -1,3 +1,2 @@\n a\n-x\n b\n",
		},
		{
			// The old side still contributes its context line, so its range is
			// "-1", not "-0,0". Verified against `git diff --no-index`.
			name: "insertion at the top keeps the old side's context line",
			a:    "a\n",
			b:    "x\na\n",
			want: "@@ -1 +1,2 @@\n+x\n a\n",
		},
		{
			name: "change at the last line clamps trailing context",
			a:    "a\nb\nc\n",
			b:    "a\nb\nC\n",
			want: "@@ -1,3 +1,3 @@\n a\n b\n-c\n+C\n",
		},
		{
			name: "empty old file inserts everything",
			a:    "",
			b:    "a\nb\n",
			want: "@@ -0,0 +1,2 @@\n+a\n+b\n",
		},
		{
			name: "empty new file deletes everything",
			a:    "a\nb\n",
			b:    "",
			want: "@@ -1,2 +0,0 @@\n-a\n-b\n",
		},
		{
			name: "no trailing newline diffs the same lines",
			a:    "a\nb",
			b:    "a\nB",
			want: "@@ -1,2 +1,2 @@\n a\n-b\n+B\n",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := unifiedDiff(diffLines(splitLines([]byte(tt.a)), splitLines([]byte(tt.b))), diffContext)
			if got != tt.want {
				t.Fatalf("unifiedDiff:\ngot:\n%s\nwant:\n%s", got, tt.want)
			}
		})
	}
}

// Two changes closer than 2*context belong to one hunk; farther apart they get
// their own, so context lines are never printed twice.
func TestUnifiedDiff_HunkMerging(t *testing.T) {
	lines := func(n int) []string {
		out := make([]string, n)
		for i := range out {
			out[i] = string(rune('a' + i%26))
		}
		return out
	}

	t.Run("near changes merge into one hunk", func(t *testing.T) {
		a := lines(20)
		b := append([]string(nil), a...)
		b[5] = "CHANGED"
		b[9] = "ALSO"
		got := unifiedDiff(diffLines(a, b), diffContext)
		if n := strings.Count(got, "@@ -"); n != 1 {
			t.Fatalf("want 1 hunk for changes 4 apart, got %d:\n%s", n, got)
		}
	})

	t.Run("far changes get separate hunks", func(t *testing.T) {
		a := lines(30)
		b := append([]string(nil), a...)
		b[3] = "CHANGED"
		b[25] = "ALSO"
		got := unifiedDiff(diffLines(a, b), diffContext)
		if n := strings.Count(got, "@@ -"); n != 2 {
			t.Fatalf("want 2 hunks for changes 22 apart, got %d:\n%s", n, got)
		}
	})
}

func TestCountEdits(t *testing.T) {
	script := diffLines(splitLines([]byte("a\nb\nc\n")), splitLines([]byte("a\nX\nY\n")))
	insertions, deletions := countEdits(script)
	if insertions != 2 || deletions != 2 {
		t.Fatalf("countEdits = %d insertions, %d deletions; want 2 and 2", insertions, deletions)
	}
}

// Past maxDiffCells the table is never allocated: the pair degrades to a
// whole-file replacement so a hostile 8 MiB file cannot size an allocation.
func TestDiffLines_OversizedPairFallsBackToReplacement(t *testing.T) {
	n := 2100 // 2100*2100 = 4.41M cells, past the 4M cap
	a := make([]string, n)
	b := make([]string, n)
	for i := range a {
		a[i] = "old " + string(rune('a'+i%26))
		b[i] = "new " + string(rune('a'+i%26))
	}
	script := diffLines(a, b)
	insertions, deletions := countEdits(script)
	if insertions != n || deletions != n {
		t.Fatalf("countEdits = %d insertions, %d deletions; want %d each", insertions, deletions, n)
	}
	for _, l := range script {
		if l.kind == diffEqual {
			t.Fatal("fallback kept an equal line; want a pure replacement")
		}
	}
}

// The shared head and tail are trimmed before the table is built, so a one-line
// edit in a file far larger than the cell cap still produces a real diff.
func TestDiffLines_TrimmingKeepsLargeFilesDiffable(t *testing.T) {
	n := 5000
	a := make([]string, n)
	for i := range a {
		a[i] = "line " + string(rune('a'+i%26))
	}
	b := append([]string(nil), a...)
	b[2500] = "CHANGED"

	got := unifiedDiff(diffLines(a, b), diffContext)
	if n := strings.Count(got, "@@ -"); n != 1 {
		t.Fatalf("want exactly 1 hunk, got %d:\n%s", n, got)
	}
	if !strings.Contains(got, "+CHANGED") {
		t.Fatalf("diff is missing the changed line:\n%s", got)
	}
}
