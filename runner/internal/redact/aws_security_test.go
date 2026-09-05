package redact

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestAWSIdentifiersRemainUsableWithoutExposingCredentials(t *testing.T) {
	rules, err := CompileAll(DefaultRules())
	if err != nil {
		t.Fatal(err)
	}
	engine := New(rules)
	for _, id := range []string{"AKIAIOSFODNN7EXAMPLE", "ASIA1234567890ABCDEF"} {
		t.Run(id, func(t *testing.T) {
			if output, _ := engine.Apply("identifier " + id); output != "identifier "+id {
				t.Fatalf("public identifier was masked: %s", output)
			}
			input := []byte(`{"AccessKeyMetadata":[{"AccessKeyId":"` + id + `","Status":"Active","SecretAccessKey":"synthetic-secret","SessionToken":"synthetic-session"}]}`)
			output, _, err := engine.ApplyJSON(input)
			if err != nil {
				t.Fatal(err)
			}
			var document struct {
				AccessKeyMetadata []map[string]string
			}
			if err := json.Unmarshal(output, &document); err != nil {
				t.Fatal(err)
			}
			row := document.AccessKeyMetadata[0]
			if row["AccessKeyId"] != id || row["Status"] != "Active" {
				t.Fatalf("discovery contract changed: %s", output)
			}
			if row["SecretAccessKey"] != "[REDACTED]" || row["SessionToken"] != "[REDACTED]" {
				t.Fatalf("credential material escaped: %s", output)
			}
		})
	}
	for _, input := range []string{
		"AWS_SECRET_ACCESS_KEY=synthetic-secret",
		"AWS_SESSION_TOKEN=synthetic-session",
		"AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE",
	} {
		if output, _ := engine.Apply(input); !strings.Contains(output, "[REDACTED]") {
			t.Fatalf("secret-named assignment policy changed: %s", output)
		}
	}
}
