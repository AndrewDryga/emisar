package capture

import (
	"testing"
	"time"
)

// RFC 6238 Appendix B, the SHA-1 rows. The published secret is the ASCII string
// "12345678901234567890"; base32 of those bytes is the constant below. These
// are the only vectors that prove the implementation is TOTP rather than
// something that merely returns six digits — which is all three rigs had, since
// none of them was tested at all.
const rfc6238Secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

func TestTOTPCodeMatchesRFC6238Vectors(t *testing.T) {
	for _, test := range []struct {
		unix int64
		want string
	}{
		{59, "287082"},
		{1111111109, "081804"},
		{1111111111, "050471"},
		{1234567890, "005924"},
		{2000000000, "279037"},
		{20000000000, "353130"},
	} {
		got, err := totpCodeAt(rfc6238Secret, time.Unix(test.unix, 0))
		if err != nil {
			t.Fatalf("t=%d: %v", test.unix, err)
		}
		if got != test.want {
			t.Errorf("t=%d: code = %s, want %s", test.unix, got, test.want)
		}
	}
}

// The three copies disagreed here: two stripped hyphens before decoding and one
// did not, so a secret pasted from a console that groups with hyphens produced a
// decode error in exactly one rig.
func TestTOTPCodeAcceptsTheGroupingProvidersDisplay(t *testing.T) {
	reference, err := totpCodeAt(rfc6238Secret, time.Unix(59, 0))
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{
		"gezdgnbvgy3tqojqgezdgnbvgy3tqojq",
		"GEZD GNBV GY3T QOJQ GEZD GNBV GY3T QOJQ",
		"GEZD-GNBV-GY3T-QOJQ-GEZD-GNBV-GY3T-QOJQ",
		" GEZDGNBVGY3TQOJQ-GEZD GNBVGY3TQOJQ ",
	} {
		got, err := totpCodeAt(secret, time.Unix(59, 0))
		if err != nil {
			t.Fatalf("%q: %v", secret, err)
		}
		if got != reference {
			t.Errorf("%q: code = %s, want %s", secret, got, reference)
		}
	}
}

func TestTOTPCodeRejectsASecretThatIsNotBase32(t *testing.T) {
	if _, err := TOTPCode("not-base32!"); err == nil {
		t.Fatal("accepted a secret that is not base32")
	}
}

// A code is what gets typed into a six-digit field; anything else is a bug the
// caller cannot see until a login silently fails.
func TestTOTPCodeIsAlwaysSixDigits(t *testing.T) {
	for step := int64(0); step < 200; step++ {
		got, err := totpCodeAt(rfc6238Secret, time.Unix(step*totpStep, 0))
		if err != nil {
			t.Fatal(err)
		}
		if len(got) != 6 {
			t.Fatalf("step %d: code = %q, want six digits", step, got)
		}
		for _, r := range got {
			if r < '0' || r > '9' {
				t.Fatalf("step %d: code = %q, want digits only", step, got)
			}
		}
	}
}
