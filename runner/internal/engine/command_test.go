package engine

import (
	"testing"

	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

func TestRedactedCommand(t *testing.T) {
	schema := []actionspec.Arg{
		{Name: "host"},
		{Name: "password", Sensitive: true},
	}

	cases := []struct {
		name   string
		binary string
		argv   []string
		args   map[string]any
		want   string
	}{
		{
			name:   "masks a sensitive arg and shell-quotes special chars",
			binary: "/usr/bin/psql",
			argv:   []string{"-h", "db1", "--password=hunter2", "a b"},
			args:   map[string]any{"host": "db1", "password": "hunter2"},
			want:   `/usr/bin/psql -h db1 '--password=[REDACTED]' 'a b'`,
		},
		{
			name:   "masks a secret embedded inside a larger flag",
			binary: "curl",
			argv:   []string{"https://u:hunter2@host/x"},
			args:   map[string]any{"password": "hunter2"},
			want:   `curl 'https://u:[REDACTED]@host/x'`,
		},
		{
			name:   "no sensitive value present passes the command through bare",
			binary: "uptime",
			argv:   []string{"-p"},
			args:   map[string]any{"host": "db1"},
			want:   `uptime -p`,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := redactedCommand(tc.binary, tc.argv, tc.args, schema)
			if got != tc.want {
				t.Fatalf("redactedCommand() = %q, want %q", got, tc.want)
			}
		})
	}
}
