package audit

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// Opening a journal needs two facts — where a torn final write ends, and the
// chain head to continue from — and both live in the last line. Reading the
// whole file for them, twice, meant a ~100 MiB allocation (the default rotation
// threshold) before `emisar doctor` printed its first line on a host that was
// already unhealthy.
func TestOpenJSONL_ReadsOnlyTheTailOfALargeJournal(t *testing.T) {
	path := filepath.Join(t.TempDir(), "events.jsonl")
	const fileBytes = 16 << 20
	lastLine := writeBulkJournal(t, path, fileBytes)

	runtime.GC()
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	sink, err := OpenJSONL(path, JSONLOptions{})
	if err != nil {
		t.Fatal(err)
	}
	runtime.ReadMemStats(&after)
	t.Cleanup(func() { _ = sink.Close() })

	// The window is MaxLineBytes+2; anything near the file size means the whole
	// journal was read. Four windows of headroom keeps this from being a
	// fixture-sensitive assertion while still failing a whole-file read by 4x.
	allocated := after.TotalAlloc - before.TotalAlloc
	if limit := uint64(4 * tailWindow); allocated > limit {
		t.Errorf("opening a %d-byte journal allocated %d bytes, want under %d", fileBytes, allocated, limit)
	}
	// Still the right answer: the chain head is the last line's digest.
	if got, want := sink.lastHash, digestOf(lastLine); got != want {
		t.Errorf("chain head = %q, want %q", got, want)
	}
}

// The window is only correct because a line longer than MaxLineBytes is
// unreadable to every reader in this package. If one is nevertheless present
// and torn, a window-only heal would find no newline and cut at a guessed
// offset — destroying complete events in the tamper-evident trail. It must fall
// back and cut in exactly the right place instead.
func TestOpenJSONL_TornLineLongerThanMaxLineBytesCutsExactly(t *testing.T) {
	path := filepath.Join(t.TempDir(), "events.jsonl")
	writeN(t, path, 3)
	complete, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	completeSize := len(complete)
	lastComplete := lastNonEmptyLine(complete)

	// A torn final write two windows long: no newline anywhere in the tail.
	torn := `{"type":"execution.completed","stdout_preview":"` + strings.Repeat("x", 2*tailWindow)
	appendRaw(t, path, torn)

	sink, err := OpenJSONL(path, JSONLOptions{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = sink.Close() })

	healed, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(healed) != completeSize {
		t.Fatalf("healed file is %d bytes, want exactly the %d complete bytes", len(healed), completeSize)
	}
	if string(healed) != string(complete) {
		t.Fatal("healing an oversized torn line rewrote the complete events")
	}
	if got, want := sink.lastHash, digestOf(lastComplete); got != want {
		t.Errorf("chain head = %q, want the last COMPLETE line %q", got, want)
	}
	// The healed journal must still verify, and keep verifying after appending.
	if err := VerifyChain(path); err != nil {
		t.Fatalf("healed chain does not verify: %v", err)
	}
}

// Every journal shape Open can meet, resolved from the tail: the chain head and
// the on-disk bytes must be exactly what a whole-file reader would produce.
func TestOpenJSONL_HealAndSeedShapes(t *testing.T) {
	tests := map[string]struct {
		body     string
		wantBody string
		wantLast string // "" = empty chain head
	}{
		"missing file":            {body: "\x00missing", wantBody: "", wantLast: ""},
		"empty file":              {body: "", wantBody: "", wantLast: ""},
		"one clean line":          {body: "a\n", wantBody: "a\n", wantLast: "a"},
		"two clean lines":         {body: "a\nb\n", wantBody: "a\nb\n", wantLast: "b"},
		"torn tail after a line":  {body: "a\nb\npartial", wantBody: "a\nb\n", wantLast: "b"},
		"whole file is one torn":  {body: "partial", wantBody: "", wantLast: ""},
		"trailing blank lines":    {body: "a\nb\n\n\n", wantBody: "a\nb\n\n\n", wantLast: "b"},
		"blank lines then a torn": {body: "a\n\n\npartial", wantBody: "a\n\n\n", wantLast: "a"},
		"only blank lines":        {body: "\n\n", wantBody: "\n\n", wantLast: ""},
	}
	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "events.jsonl")
			if tc.body != "\x00missing" {
				if err := os.WriteFile(path, []byte(tc.body), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			got, err := healAndSeed(path)
			if err != nil {
				t.Fatalf("healAndSeed: %v", err)
			}
			want := ""
			if tc.wantLast != "" {
				want = digestOf([]byte(tc.wantLast))
			}
			if got != want {
				t.Errorf("chain head = %q, want %q (last line %q)", got, want, tc.wantLast)
			}
			body, err := os.ReadFile(path)
			if err != nil && tc.body != "\x00missing" {
				t.Fatal(err)
			}
			if string(body) != tc.wantBody {
				t.Errorf("file = %q, want %q", body, tc.wantBody)
			}
		})
	}
}

// writeBulkJournal fills path with a valid chain of at least size bytes and
// returns the final line without its newline.
func writeBulkJournal(t *testing.T, path string, size int) []byte {
	t.Helper()
	sink, err := OpenJSONL(path, JSONLOptions{MaxSizeBytes: int64(size) * 8})
	if err != nil {
		t.Fatal(err)
	}
	j := New(Defaults{RunnerID: "a"}, sink)
	padding := strings.Repeat("p", 4096)
	for {
		if _, err := j.Record(context.Background(), Event{
			Type:      EventExecutionCompleted,
			ActionID:  "x.do",
			Execution: &ExecutionInfo{StdoutPreview: padding},
		}); err != nil {
			t.Fatal(err)
		}
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if info.Size() >= int64(size) {
			break
		}
	}
	if err := j.Close(); err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return append([]byte(nil), lastNonEmptyLine(body)...)
}

func appendRaw(t *testing.T, path, text string) {
	t.Helper()
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString(text); err != nil {
		t.Fatal(err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
}

func digestOf(line []byte) string {
	h := sha256.Sum256(line)
	return hex.EncodeToString(h[:])
}
