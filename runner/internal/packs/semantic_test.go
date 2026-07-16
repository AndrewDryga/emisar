package packs

import (
	"strings"
	"testing"
)

func TestLoad_RejectsInvalidConcreteActionValuesAndTemplates(t *testing.T) {
	base := strings.Replace(actionYAML("testpack.a"), "args: []", `args:
  - name: count
    type: integer
    required: false
    default: 1`, 1)

	tests := []struct {
		name    string
		replace string
		with    string
		want    string
	}{
		{
			name:    "default",
			replace: "default: 1",
			with:    "default: nope",
			want:    "invalid default",
		},
		{
			name:    "example",
			replace: "execution:",
			with: "examples:\n  - title: Bad count\n    args: {count: nope}\n" +
				"execution:",
			want: "example \"Bad count\" has invalid args",
		},
		{
			name:    "argv reference",
			replace: "argv: [\"hi\"]",
			with:    "argv: [\"{{ args.cout }}\"]",
			want:    "unknown variable args.cout",
		},
		{
			name:    "optional argv reference",
			replace: "argv: [\"hi\"]",
			with:    "argv: [\"{{ args.cout? }}\"]",
			want:    "unknown variable args.cout",
		},
		{
			name:    "env reference",
			replace: "  timeout: 5s",
			with:    "  timeout: 5s\n  env: {COUNT: \"{{ args.cout }}\"}",
			want:    "unknown variable args.cout",
		},
		{
			name:    "malformed template",
			replace: "argv: [\"hi\"]",
			with:    "argv: [\"{{ args.count\"]",
			want:    "unterminated template",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			action := strings.Replace(base, tc.replace, tc.with, 1)
			root := writePack(t, t.TempDir(), "p", map[string]string{
				"pack.yaml":      packYAML("testpack"),
				"actions/a.yaml": action,
			})
			_, err := LoadOne(root, LoadOptions{})
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("LoadOne() error = %v, want containing %q", err, tc.want)
			}
		})
	}
}

func TestLoad_AcceptsValidDefaultExampleAndReferences(t *testing.T) {
	action := strings.Replace(actionYAML("testpack.a"), "args: []", `args:
  - name: count
    type: integer
    required: false
    default: 1
    validation: {min: 1, max: 3}
  - name: labels
    type: string_array
    required: false
    default: []
    validation: {max_length: 16, max_items: 2}`, 1)
	action = strings.Replace(action, "argv: [\"hi\"]", `argv: ["{{ args.count }}", "{{ args.labels? }}"]`, 1)
	action = strings.Replace(action, "execution:", "examples:\n  - title: Valid values\n    args: {count: 2, labels: [one, two]}\nexecution:", 1)
	action = strings.Replace(action, "  timeout: 5s", "  timeout: 5s\n  env: {COUNT: \"{{ args.count }}\"}", 1)
	root := writePack(t, t.TempDir(), "p", map[string]string{
		"pack.yaml":      packYAML("testpack"),
		"actions/a.yaml": action,
	})

	if _, err := LoadOne(root, LoadOptions{}); err != nil {
		t.Fatalf("LoadOne() rejected valid semantic contract: %v", err)
	}
}
