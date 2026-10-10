package redact

import (
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"testing"

	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

func TestDefaultURLCredentialsRespectCompactJSONBoundaries(t *testing.T) {
	engine := defaultEngine(t)
	for _, backend := range []string{"http://backend", "http://backend:8080", "http://[::1]:8080"} {
		t.Run(backend, func(t *testing.T) {
			input := `{"api@file":{"loadBalancer":{"servers":[{"url":"` + backend + `"}]},"name":"api@file"}}`
			plain, hits := engine.Apply(input)
			if plain != input || len(hits) != 0 {
				t.Fatalf("URL crossed a JSON string boundary: %q (hits=%v)", plain, hits)
			}
			output, hits, err := engine.ApplyJSON([]byte(input))
			if err != nil {
				t.Fatal(err)
			}
			var want, got any
			if err := json.Unmarshal([]byte(input), &want); err != nil {
				t.Fatal(err)
			}
			if err := json.Unmarshal(output, &got); err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got, want) || len(hits) != 0 {
				t.Fatalf("ordinary Traefik data changed: %s (hits=%v)", output, hits)
			}
		})
	}
}

func TestDefaultRingIntegerMetadataRemainsVisible(t *testing.T) {
	engine := defaultEngine(t)
	for _, input := range []string{
		"Token : -9223372036854775808",
		"start_token:-9087, end_token:9123",
		"TOKEN: +123",
		"Token: 0",
		"end_token=123",
	} {
		t.Run(input, func(t *testing.T) {
			output, hits := engine.Apply(input)
			if output != input || len(hits) != 0 {
				t.Fatalf("integer metadata changed: %q (hits=%v)", output, hits)
			}
		})
	}
	output, hits := engine.Apply("Token: -123; auth_token: 456789")
	if output != "Token: -123; auth_token: [REDACTED]" || len(hits) != 1 || hits[0].Count != 1 {
		t.Fatalf("mixed metadata/credential changed: %q (hits=%v)", output, hits)
	}
}

func TestDefaultRingIntegerExceptionRetainsCredentialMasking(t *testing.T) {
	engine := defaultEngine(t)
	for _, input := range []string{
		"token=abc123", "token=-123abc", "token=123.0", "token=1e10",
		"token=--123", "token=+-123", "token=123-456", "token=+", "token=-",
		`token="123"`, `token='-123'`, `Token: -123"`,
		"auth_token=123456", "access_token=123456", "refresh_token=123456",
		"session_token=123456", "api_token=123456", "VAULT_DEV_ROOT_TOKEN_ID=123456",
		"password=123456", "secret_token=123456", "my_token=123456",
	} {
		t.Run(input, func(t *testing.T) {
			output, hits := engine.Apply(input)
			separator := strings.IndexAny(input, ":=")
			want := input[:separator+1] + " [REDACTED]"
			if input[separator+1] != ' ' {
				want = input[:separator+1] + "[REDACTED]"
			}
			if output != want || len(hits) != 1 || hits[0].Name != "secret-assignment" || hits[0].Count != 1 {
				t.Fatalf("credential or noninteger leaked: %q, want %q (hits=%v)", output, want, hits)
			}
		})
	}
}

func TestDefaultRingIntegerPredicateDoesNotOverrideAuthoredRules(t *testing.T) {
	for _, definition := range []actionspec.RedactionRule{
		{Name: "secret-assignment", Type: "regex", Pattern: `(Token: )([+-]?[0-9]+)`, Replacement: "${1}AUTHORED"},
		{Name: "secret-assignment", Type: "literal", Literal: "-123", Replacement: "AUTHORED"},
	} {
		rule, err := CompileRule(definition)
		if err != nil {
			t.Fatal(err)
		}
		output, hits := New([]Rule{rule}).Apply("Token: -123")
		if output != "Token: AUTHORED" || len(hits) != 1 || hits[0].Count != 1 {
			t.Fatalf("authored rule weakened: %q (hits=%v)", output, hits)
		}
	}
	for _, definition := range DefaultRules() {
		if definition.Name != "secret-assignment" {
			continue
		}
		definition.Replacement = "${1}AUTHORED"
		rule, err := CompileRule(definition)
		if err != nil {
			t.Fatal(err)
		}
		output, _ := New([]Rule{rule}).Apply("Token: -123")
		if output != "Token: AUTHORED" {
			t.Fatalf("custom replacement acquired a built-in exemption: %q", output)
		}
	}
	engine := defaultEngine(t).Extend([]Rule{LiteralSet("sensitive-arg", []string{"-123"}, "[REDACTED]")})
	output, hits := engine.Apply("Token: -123")
	if output != "Token: [REDACTED]" || len(hits) != 1 || hits[0].Name != "sensitive-arg" {
		t.Fatalf("sensitive literal weakened: %q (hits=%v)", output, hits)
	}
}

func TestDefaultRingIntegerStreamingAndTruncation(t *testing.T) {
	engine := defaultEngine(t)
	filler := strings.Repeat("INFO ready\n", 40)
	input := filler + "Token: -123\nstart_token:+456, end_token:0\ntoken=123credential\nauth_token=789\n" + filler
	want := filler + "Token: -123\nstart_token:+456, end_token:0\ntoken=[REDACTED]\nauth_token=[REDACTED]\n" + filler
	for _, chunk := range []int{1, 2, 7, len(input)} {
		t.Run(fmt.Sprintf("chunk-%d", chunk), func(t *testing.T) {
			output := streamAll(newSR(engine, 128), input, chunk)
			if output != want {
				t.Fatalf("stream changed metadata/credential contract: %q", output)
			}
		})
	}
	for _, input := range []string{"Token: -123", "start_token:+456", "end_token:0"} {
		output, hits := engine.ApplyOutput(input, true)
		want := input[:strings.IndexByte(input, ':')+1]
		if strings.Contains(input, ": ") {
			want += " "
		}
		want += "[REDACTED]"
		if output != want || len(hits) != 1 || hits[0].Count != 1 {
			t.Fatalf("truncated numeric prefix escaped: %q (hits=%v)", output, hits)
		}
		stream := newSR(engine, 128)
		output = string(stream.Write([]byte(filler+input))) + string(stream.Flush(true))
		if output != filler+want {
			t.Fatalf("truncated stream escaped: %q", output)
		}
	}
	output, hits := engine.ApplyOutput("Token: -123\n", true)
	if output != "Token: -123\n" || len(hits) != 0 {
		t.Fatalf("complete delimited integer was hidden: %q (hits=%v)", output, hits)
	}
}

func TestRingIntegerMetadataInJSONStringPreservesFieldSecurity(t *testing.T) {
	input := []byte(`{"message":"Token: -123","details":"start_token:+456, end_token:0","token":123,"start_token":"456","auth_token":789}`)
	output, _, err := defaultEngine(t).ApplyJSON(input)
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	if err := json.Unmarshal(output, &got); err != nil {
		t.Fatal(err)
	}
	if got["message"] != "Token: -123" || got["details"] != "start_token:+456, end_token:0" {
		t.Fatalf("metadata inside a JSON string changed: %s", output)
	}
	for _, field := range []string{"token", "start_token", "auth_token"} {
		if got[field] != "[REDACTED]" {
			t.Fatalf("actual credential field %s escaped: %s", field, output)
		}
	}
}

func TestJSONWholeAssignmentRulesStillFailClosed(t *testing.T) {
	for _, input := range []string{`["password:",123]`, `["token:",true]`} {
		output, hits, err := defaultEngine(t).ApplyJSON([]byte(input))
		if !errors.Is(err, ErrUnsafeJSONRedaction) || string(output) != "null" || len(hits) == 0 {
			t.Fatalf("whole-document protection changed: input=%s output=%s error=%v hits=%v", input, output, err, hits)
		}
	}
}

func TestRingIntegerMetadataInRootNestedAndEscapedJSON(t *testing.T) {
	for _, test := range []struct{ input, want string }{
		{`"Token: -123"`, `"Token: -123"`},
		{`[{"message":"end_token:+123"},"start_token:0"]`, `[{"message":"end_token:+123"},"start_token:0"]`},
		{`{"message":"Tok\u0065n\u003a \u002b123"}`, `{"message":"Token: +123"}`},
		{`{"message":"Token: -123\""}`, `{"message":"Token: [REDACTED]"}`},
		{`{"message":"Token: -123\\"}`, `{"message":"Token: [REDACTED]"}`},
	} {
		t.Run(test.input, func(t *testing.T) {
			output, _, err := defaultEngine(t).ApplyJSON([]byte(test.input))
			if err != nil {
				t.Fatal(err)
			}
			if string(output) != test.want {
				t.Fatalf("JSON metadata/quote contract changed: %s, want %s", output, test.want)
			}
		})
	}
}

func TestRingIntegerJSONContextRequiresCurrentValidDocument(t *testing.T) {
	rule, err := CompileRule(actionspec.RedactionRule{
		Name: "invalidate-whole-document", Type: "regex", Pattern: `"ordinary":true`, Replacement: `"ordinary`,
	})
	if err != nil {
		t.Fatal(err)
	}
	engine := defaultEngine(t).Extend([]Rule{rule})
	output, hits, err := engine.ApplyJSON([]byte(`{"message":"Token: -123","ordinary":true}`))
	if !errors.Is(err, ErrUnsafeJSONRedaction) || string(output) != "null" {
		t.Fatalf("invalidated document escaped: %s, error=%v", output, err)
	}
	foundAssignment := false
	for _, hit := range hits {
		if hit.Name == "secret-assignment" {
			foundAssignment = true
		}
	}
	if !foundAssignment {
		t.Fatalf("numeric quote exception ignored the preceding invalidation: %v", hits)
	}
}

func TestRingIntegerJSONContextDoesNotChangeRawLargeStream(t *testing.T) {
	engine := defaultEngine(t)
	input := "[\n{\"message\":\"Token: -123\"},\n" + strings.Repeat("{\"message\":\"padding\"},\n", 2000) + "{}\n]"
	if len(input) <= 2*defaultStreamHold || !json.Valid([]byte(input)) {
		t.Fatal("fixture must exceed the real hold window and be complete valid JSON")
	}
	// Raw output has no known JSON container. Preserve its existing conservative
	// quote masking, consistently for both whole buffers and committed prefixes.
	want := strings.Replace(input, `Token: -123"`, `Token: [REDACTED]`, 1)
	plain, _ := engine.Apply(input)
	if plain != want {
		t.Fatal("raw processing inferred whole-document JSON context")
	}
	for _, chunk := range []int{17, 1024, len(input)} {
		t.Run(fmt.Sprintf("chunk-%d", chunk), func(t *testing.T) {
			stream := engine.StreamRedactor()
			var output strings.Builder
			committed := false
			for position := 0; position < len(input); position += chunk {
				piece := stream.Write([]byte(input[position:min(position+chunk, len(input))]))
				committed = committed || len(piece) > 0
				output.Write(piece)
			}
			output.Write(stream.Flush(false))
			if !committed || output.String() != want {
				t.Fatal("committed stream changed raw/JSON context semantics")
			}
		})
	}
	output, _, err := engine.ApplyJSON([]byte(input))
	if err != nil {
		t.Fatal(err)
	}
	var rows []map[string]string
	if err := json.Unmarshal(output, &rows); err != nil || rows[0]["message"] != "Token: -123" {
		t.Fatalf("known complete JSON lost metadata: error=%v", err)
	}
}

func TestDefaultURLCredentialsStillMaskURIUserinfo(t *testing.T) {
	engine := defaultEngine(t)
	for _, test := range []struct{ input, want string }{
		{"postgres://reader:canary-userinfo-123@db/app", "postgres://[REDACTED]@db/app"},
		{"redis://reader:canary-userinfo-123@cache:6379", "redis://[REDACTED]@cache:6379"},
		{"postgres://o'connor:p'ass@db", "postgres://[REDACTED]@db"},
		{"postgres://reader%22name:canary%22userinfo@db", "postgres://[REDACTED]@db"},
	} {
		t.Run(test.input, func(t *testing.T) {
			output, hits := engine.Apply(test.input)
			if output != test.want || len(hits) != 1 || hits[0].Name != "url-credentials" || hits[0].Count != 1 {
				t.Fatalf("userinfo escaped: %q (hits=%v)", output, hits)
			}
			input, err := json.Marshal(map[string]string{"endpoint": test.input})
			if err != nil {
				t.Fatal(err)
			}
			outputJSON, _, err := engine.ApplyJSON(input)
			if err != nil {
				t.Fatal(err)
			}
			var got map[string]string
			if err := json.Unmarshal(outputJSON, &got); err != nil {
				t.Fatal(err)
			}
			if got["endpoint"] != test.want {
				t.Fatalf("JSON userinfo escaped: %s", outputJSON)
			}
		})
	}
	// The JSON scalar pass sees decoded slashes and Unicode escapes, not these
	// original bytes. It must still redact before the whole-document pass.
	output, _, err := engine.ApplyJSON([]byte(`{"endpoint":"postgres:\/\/reader:canary-\u0075serinfo@db"}`))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(output), "canary-") || !strings.Contains(string(output), "[REDACTED]@db") {
		t.Fatalf("escaped JSON userinfo leaked: %s", output)
	}
}
