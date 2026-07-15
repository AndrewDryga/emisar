package redact

import (
	"strings"
	"testing"
)

// the soundness gate (strings.HasPrefix, stream.go:96-100) must
// HOLD a segment rather than emit it when a newline-boundary cut would split a
// match that has already closed further along. Here the hold (256 B) exceeds
// the PEM block (~125 B), and committed filler before it makes the block's
// opening lines positionally eligible to commit — yet none of the block's body
// may be emitted until the closing line arrives. Observed write-by-write, which
// is finer-grained than the whole-output equality in
// TestStreamRedactor_MatchesWholeBufferRedaction.
func TestStreamRedactor_SoundnessGateHoldsSplitMatch(t *testing.T) {
	eng := defaultEngine(t)
	const hold = 256
	sr := newSR(eng, hold)

	// Filler larger than the hold so the commit cut advances and the PEM's
	// BEGIN line becomes positionally committable.
	filler := strings.Repeat("INFO benign line here, nothing to see ok\n", 12) // > hold
	var emitted strings.Builder
	emitted.WriteString(string(sr.Write([]byte(filler))))
	if emitted.Len() == 0 {
		t.Fatal("benign filler past the hold should have committed incrementally")
	}

	// Feed the PEM block one line at a time. The gate must hold the opening
	// lines: at no point before the block closes may any key body escape.
	for _, line := range strings.SplitAfter(shortPEM, "\n") {
		if line == "" {
			continue
		}
		emitted.WriteString(string(sr.Write([]byte(line))))
		if strings.Contains(emitted.String(), "LEAKYKEYBODY") {
			t.Fatalf("soundness gate failed: key body emitted before the block closed:\n%s", emitted.String())
		}
	}

	emitted.WriteString(string(sr.Flush()))
	got := emitted.String()
	if strings.Contains(got, "LEAKYKEYBODY") {
		t.Fatalf("key body leaked after flush:\n%s", got)
	}
	if !strings.Contains(got, "[REDACTED_PRIVATE_KEY]") {
		t.Fatalf("expected private-key marker after flush, got:\n%s", got)
	}
}

// the commit cut is always taken just after the last newline in
// the committable region (indexAfterLastNewline, stream.go:88,110-122). With no
// newline in that region nothing is emitted; once a newline lands inside it, the
// prefix up to and including that newline is released.
func TestStreamRedactor_CutsOnlyOnNewlineBoundary(t *testing.T) {
	eng := defaultEngine(t) // engine choice is irrelevant; none of this matches a rule
	sr := newSR(eng, 8)

	// A long run with no newline: even though len(pending) > hold, there is no
	// newline boundary in the committable region, so nothing is emitted.
	noNewline := "0123456789012345678901234567890123456789" // 40 B, no '\n'
	if out := sr.Write([]byte(noNewline)); len(out) != 0 {
		t.Fatalf("no newline in committable region: expected no emit, got %q", out)
	}

	// Now introduce a newline followed by enough trailing bytes that the newline
	// falls within the committable region (before len-hold). The prefix up to
	// and including that newline is emitted; the tail stays held.
	out := string(sr.Write([]byte("\n" + strings.Repeat("Z", 20))))
	if !strings.HasSuffix(out, "\n") {
		t.Fatalf("emit must end on the newline boundary, got %q", out)
	}
	if out != noNewline+"\n" {
		t.Fatalf("expected exactly the pre-newline prefix, got %q", out)
	}
	if strings.Contains(out, "Z") {
		t.Fatalf("held tail (after the newline) must not be emitted yet, got %q", out)
	}
}

// Private-key delimiters are handled independently of the generic regex hold
// window, so even an unusually large key body is suppressed incrementally.
func TestStreamRedactor_OversizedPrivateKeyNeverLeaks(t *testing.T) {
	eng := defaultEngine(t)
	body := strings.Repeat("LEAKYKEYBODY0123456789ABCDEF\n", 1024) // ~28 KiB > 16 KiB hold
	for _, tc := range []struct {
		name  string
		begin string
		end   string
	}{
		{name: "pem", begin: "-----BEGIN RSA PRIVATE KEY-----\n", end: "-----END RSA PRIVATE KEY-----\n"},
		{name: "pgp", begin: "-----BEGIN PGP PRIVATE KEY BLOCK-----\n", end: "-----END PGP PRIVATE KEY BLOCK-----\n"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			input := "before\n" + tc.begin + body + tc.end + "after\n"
			if len(input) <= defaultStreamHold {
				t.Fatalf("test block (%d B) must exceed the default hold (%d B)", len(input), defaultStreamHold)
			}
			out := streamAll(eng.StreamRedactor(), input, 4096)
			if strings.Contains(out, "LEAKYKEYBODY") {
				t.Fatalf("oversized private-key body leaked: %q", out)
			}
			if !strings.Contains(out, "before\n[REDACTED_PRIVATE_KEY]\nafter") {
				t.Fatalf("unexpected redacted output: %q", out)
			}
		})
	}
}

// Executor output limits can cut a key block before its END marker. Flush must
// keep suppressing that open block rather than release the buffered body.
func TestStreamRedactor_UnterminatedPrivateKeyMasksThroughEOF(t *testing.T) {
	eng := defaultEngine(t)
	sr := eng.StreamRedactor()
	input := "before\n-----BEGIN RSA PRIVATE KEY-----\n" +
		strings.Repeat("TRUNCATEDKEYBODY0123456789\n", 2048)
	var emitted strings.Builder
	for i := 0; i < len(input); i += 1024 {
		end := i + 1024
		if end > len(input) {
			end = len(input)
		}
		emitted.Write(sr.Write([]byte(input[i:end])))
	}
	emitted.Write(sr.Flush())
	out := emitted.String()
	if strings.Contains(out, "TRUNCATEDKEYBODY") {
		t.Fatalf("unterminated private-key body leaked at EOF: %q", out)
	}
	if out != "before\n[REDACTED_PRIVATE_KEY]" {
		t.Fatalf("unexpected redacted output: %q", out)
	}
	if len(sr.keys.pending) > len("-----END RSA PRIVATE KEY-----") {
		t.Fatalf("delimiter scanner retained %d bytes of a truncated body", len(sr.keys.pending))
	}
}

func TestStreamRedactor_NonPrivatePEMBlockPassesThrough(t *testing.T) {
	eng := defaultEngine(t)
	certificate := "-----BEGIN CERTIFICATE-----\nPUBLICBODY\n-----END CERTIFICATE-----\n"
	if got := streamAll(eng.StreamRedactor(), certificate, 1); got != certificate {
		t.Fatalf("non-private PEM block changed: %q", got)
	}
}

// empty / zero-length input must not panic and must emit nothing.
func TestStreamRedactor_EmptyWriteAndFlush(t *testing.T) {
	eng := defaultEngine(t)
	sr := newSR(eng, 8)

	if out := sr.Write(nil); out != nil {
		t.Fatalf("Write(nil) should emit nothing, got %q", out)
	}
	if out := sr.Write([]byte{}); out != nil {
		t.Fatalf("Write(empty) should emit nothing, got %q", out)
	}
	if out := sr.Flush(); out != nil {
		t.Fatalf("Flush on empty buffer should emit nothing, got %q", out)
	}
	// Hits over an untouched stream are empty.
	if hits := sr.Hits(); len(hits) != 0 {
		t.Fatalf("expected no hits on an empty stream, got %+v", hits)
	}
}

// streaming throughput vs the hold + soundness re-redact
// overhead. Baseline only; guards against accidental quadratic behavior in the
// commit path over a large stream.
func BenchmarkStreamRedactor_LargeStream(b *testing.B) {
	rules, err := CompileAll(DefaultRules())
	if err != nil {
		b.Fatal(err)
	}
	eng := New(rules)

	var sb strings.Builder
	for sb.Len() < 256<<10 { // 256 KiB of benign-ish output
		sb.WriteString("INFO 2026-06-21 handled request status=200 path=/v1/x in 9ms\n")
	}
	input := []byte(sb.String())

	b.ReportAllocs()
	b.SetBytes(int64(len(input)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		sr := eng.StreamRedactor()
		for j := 0; j < len(input); j += 4096 {
			end := j + 4096
			if end > len(input) {
				end = len(input)
			}
			_ = sr.Write(input[j:end])
		}
		_ = sr.Flush()
	}
}
