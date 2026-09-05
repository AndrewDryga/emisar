package redact

import (
	"fmt"
	"strings"
	"testing"
)

func TestStreamRedactor_LongKnownLiteralsRemainMasked(t *testing.T) {
	secret := strings.Repeat("sensitive multiline value\n", 1300)
	filler := strings.Repeat("ordinary output\n", 3000)
	input := filler + secret + filler

	for _, tc := range []struct {
		name string
		rule Rule
	}{
		{"literal", Rule{Name: "literal", literal: secret, Replacement: "[REDACTED]"}},
		{"sensitive arguments", LiteralSet("arguments", []string{"another-value", secret}, "[REDACTED]")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			eng := New([]Rule{tc.rule})
			want, _ := eng.Apply(input)
			for _, chunk := range []int{1, 13, 4096, defaultStreamHold, len(input)} {
				t.Run(fmt.Sprintf("chunk_%d", chunk), func(t *testing.T) {
					got := streamAll(eng.StreamRedactor(), input, chunk)
					if got != want {
						t.Fatalf("streaming differs from whole-buffer redaction: got %d bytes, want %d", len(got), len(want))
					}
					if strings.Contains(got, "sensitive multiline") {
						t.Fatal("a sensitive literal prefix left the redactor")
					}
				})
			}
		})
	}
}

func TestRedactor_TruncatedLiteralPrefixesRemainMasked(t *testing.T) {
	for _, tc := range []struct {
		name      string
		literals  []string
		input     string
		truncated bool
		want      string
	}{
		{"partial only", []string{"abc\ndef"}, "safe\nabc\nd", true, "safe\n[REDACTED]"},
		{"complete output keeps unrelated suffix", []string{"abc\ndef"}, "safe\nabc\nd", false, "safe\nabc\nd"},
		{"overlapping partial", []string{"abc", "bcdefghijkl"}, "abcdef", true, "[REDACTED]"},
		{"overlapping complete", []string{"abc", "bcdefghijkl"}, "abcdefghijkl", false, "[REDACTED]"},
		{"replacement is not rescanned", []string{"ED", "abc\ndef"}, "abc\nd", true, "[REDACTED]"},
		{"short partial covers full match", []string{"abcde", "abcdefg"}, "abcdef", true, "[REDACTED]"},
		{"ordinary truncated output", []string{"abc\ndef"}, "ordinary output", true, "ordinary output"},
		{"one-byte partial", []string{"abc\ndef"}, "safe a", true, "safe [REDACTED]"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			eng := New([]Rule{LiteralSet("arguments", tc.literals, "[REDACTED]")})
			if got, _ := eng.ApplyOutput(tc.input, tc.truncated); got != tc.want {
				t.Fatalf("buffered: got %q, want %q", got, tc.want)
			}
			for _, chunk := range []int{1, 7, len(tc.input)} {
				sr := eng.StreamRedactor()
				var got strings.Builder
				for i := 0; i < len(tc.input); i += chunk {
					got.Write(sr.Write([]byte(tc.input[i:min(i+chunk, len(tc.input))])))
				}
				got.Write(sr.Flush(tc.truncated))
				if got.String() != tc.want {
					t.Fatalf("chunk %d: got %q, want %q", chunk, got.String(), tc.want)
				}
			}
		})
	}
}

func TestStreamRedactor_OverlappingLiteralsStayTogether(t *testing.T) {
	a := strings.Repeat("a", 9000) + "\n"
	b := strings.Repeat("b", 9000) + "\n"
	c := strings.Repeat("c", 9000) + "\n"
	filler := strings.Repeat("x", 9000) + "\n"
	input := a + b + c + filler
	eng := New([]Rule{LiteralSet("arguments", []string{a + b, b + c}, "[REDACTED]")})
	want, _ := eng.Apply(input)
	for _, chunk := range []int{4096, len(input)} {
		if got := streamAll(eng.StreamRedactor(), input, chunk); got != want {
			t.Fatalf("chunk %d split overlapping literals: got %d bytes, want %d", chunk, len(got), len(want))
		}
	}
}
