package redact

import (
	"strings"
	"testing"
)

// newSR returns a StreamRedactor with a small hold window so the commit /
// back-off paths are exercised by tiny inputs. Production uses
// defaultStreamHold; the logic under test is identical, only the buffer
// threshold differs, so small inputs keep these tests fast (the default-sized
// window over realistic input is covered by TestStreamRedactor_DefaultHoldCoversPEM).
func newSR(eng *Engine, hold int) *StreamRedactor {
	sr := eng.StreamRedactor()
	sr.hold = hold
	return sr
}

// streamAll feeds input through sr in fixed-size chunks (crossing line and
// rule boundaries arbitrarily) and returns the full redacted output, tail
// included.
func streamAll(sr *StreamRedactor, input string, chunk int) string {
	var out strings.Builder
	b := []byte(input)
	for i := 0; i < len(b); i += chunk {
		end := i + chunk
		if end > len(b) {
			end = len(b)
		}
		out.Write(sr.Write(b[i:end]))
	}
	out.Write(sr.Flush())
	return out.String()
}

func defaultEngine(t *testing.T) *Engine {
	t.Helper()
	rules, err := CompileAll(DefaultRules())
	if err != nil {
		t.Fatal(err)
	}
	return New(rules)
}

// shortPEM is a private-key block whose body is unmistakable filler so a leak
// is trivial to detect. Small so a tiny hold window still covers it.
const shortPEM = "-----BEGIN RSA PRIVATE KEY-----\n" +
	"AAAALEAKYKEYBODYAAAA\nBBBBLEAKYKEYBODYBBBB\nCCCCLEAKYKEYBODYCCCC\n" +
	"-----END RSA PRIVATE KEY-----\n"

// TestStreamRedactor_MultiLinePEMNeverLeaks is the headline regression: a PEM
// private key delivered one line at a time must be redacted as a whole block,
// not emitted line-by-line (which the multi-line rule would never match).
func TestStreamRedactor_MultiLinePEMNeverLeaks(t *testing.T) {
	eng := defaultEngine(t)

	var out strings.Builder
	sr := newSR(eng, 256) // hold must exceed the block; the block is ~125 B
	for _, line := range strings.SplitAfter(shortPEM, "\n") {
		if line == "" {
			continue
		}
		out.Write(sr.Write([]byte(line)))
	}
	out.Write(sr.Flush())

	got := out.String()
	if strings.Contains(got, "LEAKYKEYBODY") {
		t.Fatalf("PEM body leaked through line-by-line streaming:\n%s", got)
	}
	if !strings.Contains(got, "[REDACTED_PRIVATE_KEY]") {
		t.Fatalf("expected the private-key redaction marker, got:\n%s", got)
	}
}

// TestStreamRedactor_MatchesWholeBufferRedaction is the core soundness
// property: for any chunking, streamed redaction must equal redacting the whole
// buffer at once (for secrets within the hold window). The PEM is embedded in
// benign filler larger than the hold window so the block commits live, before
// flush — the path a naive implementation leaks on.
func TestStreamRedactor_MatchesWholeBufferRedaction(t *testing.T) {
	eng := defaultEngine(t)

	// hold (256) exceeds the ~125 B block, and each filler run (~456 B)
	// exceeds hold — so the block commits live, surrounded by committed filler.
	const hold = 256
	filler := strings.Repeat("INFO processing batch, all green here\n", 12) // ~456 B > hold
	input := filler + shortPEM + filler
	want, _ := eng.Apply(input)

	for _, chunk := range []int{1, 7, 64, 512, len(input)} {
		got := streamAll(newSR(eng, hold), input, chunk)
		if got != want {
			t.Fatalf("chunk=%d: streamed redaction != whole-buffer redaction\nwant:\n%s\ngot:\n%s", chunk, want, got)
		}
	}
	// And the secret really is gone in the streamed form.
	out := streamAll(newSR(eng, hold), input, 7)
	if strings.Contains(out, "LEAKYKEYBODY") {
		t.Fatalf("PEM body leaked on the commit path")
	}
}

// TestStreamRedactor_DefaultHoldCoversPEM proves the production hold window is
// large enough that a realistic PEM key (here padded near a few KiB) is fully
// contained before any of its lines are eligible to emit.
func TestStreamRedactor_DefaultHoldCoversPEM(t *testing.T) {
	eng := defaultEngine(t)
	pem := "-----BEGIN RSA PRIVATE KEY-----\n" +
		strings.Repeat("MIIEowIBAAKCAQEALEAKYKEYBODY0123456789abcdefABCDEF0123456789xyz\n", 40) + // ~2.5 KiB
		"-----END RSA PRIVATE KEY-----\n"
	if len(pem) >= defaultStreamHold {
		t.Fatalf("test PEM (%d B) should fit under the default hold window (%d B)", len(pem), defaultStreamHold)
	}
	out := streamAll(eng.StreamRedactor(), pem, 41) // real default hold
	if strings.Contains(out, "LEAKYKEYBODY") {
		t.Fatalf("PEM body leaked under the default hold window")
	}
	if !strings.Contains(out, "[REDACTED_PRIVATE_KEY]") {
		t.Fatalf("expected redaction marker under default hold, got:\n%s", out)
	}
}

// TestStreamRedactor_SingleLineSecretSplitAcrossChunks — a token split mid-
// value across two writes is still caught (it lands in one line, redacted as a
// unit before emit).
func TestStreamRedactor_SingleLineSecretSplitAcrossChunks(t *testing.T) {
	eng := defaultEngine(t)
	sr := newSR(eng, 8)

	var out strings.Builder
	out.Write(sr.Write([]byte("Authorization: Bearer abc123")))
	out.Write(sr.Write([]byte("def456ghi789jklmno\n")))
	out.Write(sr.Flush())

	got := out.String()
	if strings.Contains(got, "abc123def456ghi789jklmno") {
		t.Fatalf("split bearer token leaked: %q", got)
	}
	if !strings.Contains(got, "[REDACTED]") {
		t.Fatalf("expected bearer redaction, got %q", got)
	}
}

// TestStreamRedactor_EmitsBeforeFlush — benign output past the hold window must
// stream out incrementally, not pile up until Flush (that would defeat live
// progress) — and every inert byte must come out exactly once.
func TestStreamRedactor_EmitsBeforeFlush(t *testing.T) {
	eng := defaultEngine(t)
	sr := newSR(eng, 64)

	line := "INFO heartbeat ok, nothing to redact on this line\n"
	emittedBeforeFlush := 0
	for i := 0; i < 40; i++ { // well past the 64-byte hold
		emittedBeforeFlush += len(sr.Write([]byte(line)))
	}
	if emittedBeforeFlush == 0 {
		t.Fatal("nothing emitted before flush; live streaming is starved")
	}
	tail := sr.Flush()
	if full := emittedBeforeFlush + len(tail); full != 40*len(line) {
		t.Fatalf("byte accounting off: emitted %d, want %d", full, 40*len(line))
	}
}

// TestStreamRedactor_Hits — cumulative hit counts across commits and the flush
// must equal a single whole-buffer Apply over the same input.
func TestStreamRedactor_Hits(t *testing.T) {
	eng := defaultEngine(t)

	filler := strings.Repeat("benign line, no secrets here\n", 8)
	input := filler + "token=supersecretvalue1234567890\n" + filler +
		"Authorization: Bearer zzzzzzzzzzzzzzzzzzzz\n" + filler

	_, wantHits := eng.Apply(input)
	wantTotal := 0
	for _, h := range wantHits {
		wantTotal += h.Count
	}

	sr := newSR(eng, 32)
	streamAll(sr, input, 16)
	gotTotal := 0
	for _, h := range sr.Hits() {
		gotTotal += h.Count
	}
	if gotTotal != wantTotal {
		t.Fatalf("streamed hit total %d != whole-buffer hit total %d", gotTotal, wantTotal)
	}
}

// TestStreamRedactor_NoRulesPassthrough — an empty engine must return input
// unchanged regardless of chunking.
func TestStreamRedactor_NoRulesPassthrough(t *testing.T) {
	eng := Empty()
	input := "plain text\nwith several lines\nand no rules\n"
	for _, chunk := range []int{1, 3, len(input)} {
		if got := streamAll(newSR(eng, 8), input, chunk); got != input {
			t.Fatalf("chunk=%d: passthrough altered input: %q", chunk, got)
		}
	}
}
