package redact

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

func TestConsulSecretIDsAreMaskedWithoutHidingAccessors(t *testing.T) {
	const secret = "11111111-1111-4111-8111-111111111111"
	const accessor = "22222222-2222-4222-8222-222222222222"
	engine := defaultEngine(t)
	for _, test := range []struct {
		name, input, field string
	}{
		{"glued", `{"SecretID":"` + secret + `","AccessorID":"` + accessor + `"}`, "SecretID"},
		{"spaced", `{"Secret ID":"` + secret + `","AccessorID":"` + accessor + `"}`, "Secret ID"},
		{"underscored", `{"secret_id":"` + secret + `","AccessorID":"` + accessor + `"}`, "secret_id"},
		{"escaped key", `{"Secret\u0049D":"` + secret + `","AccessorID":"` + accessor + `"}`, "SecretID"},
		{"escaped value", `{"SecretID":"prefix\\\"` + secret + `","AccessorID":"` + accessor + `"}`, "SecretID"},
	} {
		t.Run(test.name, func(t *testing.T) {
			output, hits, err := engine.ApplyJSON([]byte(test.input))
			if err != nil {
				t.Fatal(err)
			}
			var row map[string]string
			if err := json.Unmarshal(output, &row); err != nil {
				t.Fatal(err)
			}
			if row[test.field] != "[REDACTED]" || len(hits) == 0 || strings.Contains(string(output), secret) {
				t.Fatalf("SecretID exposed: %s (hits=%v)", output, hits)
			}
			if row["AccessorID"] != accessor {
				t.Fatalf("AccessorID hidden: %s", output)
			}
		})
	}

	filler := strings.Repeat("INFO ready\n", 40)
	input := filler + "SecretID: " + secret + "\nSecret ID: " + secret + "\nsecret_id: " + secret + "\nAccessorID: " + accessor + "\n" + filler
	want, _ := engine.Apply(input)
	for _, chunk := range []int{1, 7, len(input)} {
		t.Run(fmt.Sprintf("stream chunk %d", chunk), func(t *testing.T) {
			output := streamAll(newSR(engine, 128), input, chunk)
			if output != want || strings.Contains(output, secret) || !strings.Contains(output, accessor) {
				t.Fatalf("stream changed identifier/secret contract: %q", output)
			}
		})
	}
}
