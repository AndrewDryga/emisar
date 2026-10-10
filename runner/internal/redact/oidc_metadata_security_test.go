package redact

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

func TestPublicOIDCMetadataFieldsRemainVisible(t *testing.T) {
	for _, input := range []string{
		`{"id_token_signing_alg_values_supported":["RS256","ES256"],"token_endpoint_auth_methods_supported":["client_secret_basic","private_key_jwt"]}`,
		`{"nested":{"id_token_signing_alg_values_supported":"RS256","token_endpoint_auth_methods_supported":"client_secret_basic"}}`,
		`{"id\u005ftoken_signing_alg_values_supported":["RS256"]}`,
	} {
		t.Run(input, func(t *testing.T) {
			output, hits, err := defaultEngine(t).ApplyJSON([]byte(input))
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
			if !reflect.DeepEqual(want, got) || len(hits) != 0 {
				t.Fatalf("public metadata changed: %s (hits=%v)", output, hits)
			}
		})
	}
}

func TestOIDCMetadataExceptionStillMasksCredentials(t *testing.T) {
	input := `{
		"id_token_signing_alg_values_supported":["RS256","Bearer credential123"],
		"token_endpoint_auth_methods_supported":["client_secret_basic",{"password":"nested-hidden"}],
		"client_secret_supported":{"value":"object-hidden"},
		"access_token_supported":["array-hidden"],
		"id_token_signing_alg_values_supported_extra":"suffix-hidden",
		"ID_TOKEN_SIGNING_ALG_VALUES_SUPPORTED":"case-hidden",
		"token_endpoint_auth_methods_supported_v2":false,
		"client_secret":42,
		"token":null
	}`
	output, hits, err := defaultEngine(t).ApplyJSON([]byte(input))
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	if err := json.Unmarshal(output, &got); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got["id_token_signing_alg_values_supported"], []any{"RS256", "Bearer [REDACTED]"}) ||
		!reflect.DeepEqual(got["token_endpoint_auth_methods_supported"], []any{"client_secret_basic", map[string]any{"password": "[REDACTED]"}}) {
		t.Fatalf("metadata values bypassed recursive credential rules: %s", output)
	}
	for _, key := range []string{"client_secret_supported", "access_token_supported", "id_token_signing_alg_values_supported_extra", "ID_TOKEN_SIGNING_ALG_VALUES_SUPPORTED", "token_endpoint_auth_methods_supported_v2", "client_secret", "token"} {
		if got[key] != "[REDACTED]" {
			t.Errorf("credential/non-allowlisted field %s survived: %#v", key, got[key])
		}
	}
	if len(hits) == 0 {
		t.Fatal("credential masking reported no hits")
	}
}

func TestOIDCMetadataExceptionDoesNotOverrideAuthoredRules(t *testing.T) {
	var builtin actionspec.RedactionRule
	for _, definition := range DefaultRules() {
		if definition.Name == "json-secret-field" {
			builtin = definition
		}
	}
	customReplacement := builtin
	customReplacement.Replacement = `${1}"AUTHORED"${3}`
	for _, definition := range []actionspec.RedactionRule{
		customReplacement,
		{Name: "json-secret-field", Type: "regex", Pattern: `("id_token_signing_alg_values_supported":)"[^"]*"`, Replacement: `${1}"AUTHORED"`},
		{Name: "json-secret-field", Type: "literal", Literal: "RS256", Replacement: "AUTHORED"},
		{Name: "action-metadata", Type: "regex", Pattern: `("id_token_signing_alg_values_supported":)"[^"]*"`, Replacement: `${1}"AUTHORED"`},
	} {
		t.Run(definition.Name+definition.Pattern, func(t *testing.T) {
			rules, err := CompileAll([]actionspec.RedactionRule{definition}, DefaultRules())
			if err != nil {
				t.Fatal(err)
			}
			output, hits, err := New(rules).ApplyJSON([]byte(`{"id_token_signing_alg_values_supported":"RS256"}`))
			if err != nil || string(output) != `{"id_token_signing_alg_values_supported":"AUTHORED"}` || len(hits) == 0 {
				t.Fatalf("authored rule weakened: %s (hits=%v, error=%v)", output, hits, err)
			}
		})
	}
	rule := LiteralSet("sensitive-arg", []string{"RS256"}, "[REDACTED]")
	output, hits, err := defaultEngine(t).Extend([]Rule{rule}).ApplyJSON([]byte(`{"id_token_signing_alg_values_supported":["RS256"]}`))
	if err != nil || string(output) != `{"id_token_signing_alg_values_supported":["[REDACTED]"]}` || len(hits) != 1 || hits[0].Name != "sensitive-arg" {
		t.Fatalf("sensitive literal weakened: %s (hits=%v, error=%v)", output, hits, err)
	}
}

func TestOIDCMetadataTextAndStreamKeepOtherRules(t *testing.T) {
	input := `{"id_token_signing_alg_values_supported":"RS256","token_endpoint_auth_methods_supported":"client_secret_basic","client_secret_supported":"hidden"}` + "\n"
	want := strings.Replace(input, `"hidden"`, `"[REDACTED]"`, 1)
	output, hits := defaultEngine(t).Apply(input)
	if output != want || len(hits) != 1 || hits[0].Name != "json-secret-field" || hits[0].Count != 1 {
		t.Fatalf("text metadata/credential contract changed: %q (hits=%v)", output, hits)
	}
	for _, chunk := range []int{1, 7, len(input)} {
		if got := streamAll(newSR(defaultEngine(t), 128), input, chunk); got != want {
			t.Fatalf("chunk=%d: stream contract changed: %q", chunk, got)
		}
	}
}
