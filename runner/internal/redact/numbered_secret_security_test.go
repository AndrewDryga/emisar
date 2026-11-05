package redact

import (
	"bytes"
	"strings"
	"testing"
)

// A digit straight after a secret name is how a second credential gets named:
// MySQL's own password1, DB_PASSWORD2, token2. A secret word followed by any
// other letters is a different word and stays readable.
func TestDefaultRules_MaskSecretNamesWithADigitOnTheEnd(t *testing.T) {
	const secret = "numberedsecretvalue"
	for _, input := range []string{
		"password1=" + secret,
		"mysql: unknown variable 'password1=" + secret + "'",
		"DB_PASSWORD2=" + secret,
		"PGPASSWORD12=" + secret,
		"SECRET1=" + secret,
		"token2=" + secret,
		"api_key2: " + secret,
		"client_secret2 = " + secret,
		"password1_old=" + secret,
		`{"password1":"` + secret + `"}`,
		`{"token2":"` + secret + `","ok":1}`,
		`{'api_key2': '` + secret + `'}`,
	} {
		t.Run(input, func(t *testing.T) {
			out, hits := defaultApply(t, input)
			if strings.Contains(out, secret) {
				t.Fatalf("secret not redacted: %q", out)
			}
			if len(hits) == 0 {
				t.Fatalf("expected a hit for %q", input)
			}
		})
	}
}

func TestDefaultRules_KeepWordsThatOnlyStartWithASecretName(t *testing.T) {
	for _, input := range []string{
		"tokens=12",
		"tokenizer2=bert",
		"password2fa=enabled",
		"secretary1=alice",
		"sha256=abc123",
	} {
		t.Run(input, func(t *testing.T) {
			out, hits := defaultApply(t, input)
			if out != input {
				t.Fatalf("readable name was altered: %q", out)
			}
			if hits != nil {
				t.Fatalf("expected no hits, got %+v", hits)
			}
		})
	}
}

func TestApplyJSON_MasksANumberedSecretKey(t *testing.T) {
	const secret = "numberedsecretvalue"
	rules, err := CompileAll(DefaultRules())
	if err != nil {
		t.Fatal(err)
	}
	out, _, err := New(rules).ApplyJSON([]byte(`{"password1":"` + secret + `","count":3}`))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(out, []byte(secret)) {
		t.Fatalf("secret not redacted: %s", out)
	}
	if !bytes.Contains(out, []byte(`"count":3`)) {
		t.Fatalf("unrelated field was altered: %s", out)
	}
}

// A chunk boundary can fall between the name and its digit.
func TestStreamRedactor_MasksANumberedSecretName(t *testing.T) {
	const secret = "numberedsecretvalue"
	input := "starting\nDB_PASSWORD2=" + secret + "\nfinished\n"
	rules, err := CompileAll(DefaultRules())
	if err != nil {
		t.Fatal(err)
	}
	eng := New(rules)
	for _, chunk := range []int{1, 13, len("starting\nDB_PASSWORD"), len(input)} {
		got := streamAll(eng.StreamRedactor(), input, chunk)
		if strings.Contains(got, secret) {
			t.Fatalf("chunk %d: secret not redacted: %q", chunk, got)
		}
		if !strings.Contains(got, "finished") {
			t.Fatalf("chunk %d: unrelated output was lost: %q", chunk, got)
		}
	}
}
