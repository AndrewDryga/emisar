package devtool

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestValidatePackDBReadBounds(t *testing.T) {
	bounded := "SET LOCAL statement_timeout = '8s'; SET LOCAL lock_timeout = '5s'; SELECT 1;"
	boundedMySQL := "SET SESSION lock_wait_timeout=5 /*!50708 , max_execution_time=8000 */ /*M!100108 , max_statement_time=8 */; SHOW ENGINES"
	for _, test := range []struct {
		name    string
		id      string
		binary  string
		argv    []string
		env     map[string]string
		wantErr string
	}{
		{
			// The shape that wrote through a pooler while promising read-only.
			name:    "a startup option set by the action",
			id:      "fixture.read",
			binary:  "psql",
			argv:    []string{"-XAtq", "-c", bounded},
			env:     map[string]string{"PGOPTIONS": "-c default_transaction_read_only=on"},
			wantErr: "fixture.read (PGOPTIONS",
		},
		{
			name:    "a startup option on an exempt action",
			id:      "postgres.vacuum_table",
			binary:  "psql",
			argv:    []string{"-XAt", "-c", "VACUUM orders"},
			env:     map[string]string{"PGOPTIONS": "-c lock_timeout=5s"},
			wantErr: "postgres.vacuum_table (PGOPTIONS",
		},
		{name: "bounded psql", id: "fixture.read", binary: "psql", argv: []string{"-XAtq", "-c", bounded}},
		{name: "bounded mysql", id: "fixture.read", binary: "mysql", argv: []string{"-e", boundedMySQL}},
		{name: "another client", id: "fixture.read", binary: "redis-cli", argv: []string{"INFO"}},
		{name: "exempt maintenance", id: "postgres.vacuum_table", binary: "psql", argv: []string{"-XAt", "-c", "VACUUM orders"}},
		{
			name:    "bare psql read",
			id:      "fixture.read",
			binary:  "psql",
			argv:    []string{"-XAt", "-c", "SELECT 1"},
			wantErr: "fixture.read (psql without statement_timeout), fixture.read (psql without lock_timeout)",
		},
		{
			name:    "psql with only a statement limit",
			id:      "fixture.read",
			binary:  "psql",
			argv:    []string{"-XAtq", "-c", "SET LOCAL statement_timeout = '8s'; SELECT 1;"},
			wantErr: "fixture.read (psql without lock_timeout)",
		},
		{
			name:    "mysql with no MariaDB limit",
			id:      "fixture.read",
			binary:  "mysql",
			argv:    []string{"-e", "SET SESSION lock_wait_timeout=5, max_execution_time=8000; SHOW ENGINES"},
			wantErr: "fixture.read (mysql without max_statement_time)",
		},
		{
			name:    "a client inside a shell program",
			id:      "fixture.read",
			binary:  "/bin/sh",
			argv:    []string{"-c", "mysql -e 'SHOW REPLICA STATUS'"},
			wantErr: "fixture.read (mysql without lock_wait_timeout)",
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			packDir := t.TempDir()
			actionDir := filepath.Join(packDir, "actions")
			if err := os.MkdirAll(actionDir, 0o755); err != nil {
				t.Fatal(err)
			}
			action := encodeFixtureAction(t, test.id, map[string]any{
				"command": map[string]any{"binary": test.binary, "argv": test.argv},
				"env":     test.env,
			})
			if err := os.WriteFile(filepath.Join(actionDir, "fixture.yaml"), action, 0o644); err != nil {
				t.Fatal(err)
			}

			err := validatePackDBReadBounds(fixturePackActionLintInput(t, packDir))
			if test.wantErr == "" {
				if err != nil {
					t.Fatalf("unexpected error: %v", err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), test.wantErr) {
				t.Fatalf("error = %v, want %q", err, test.wantErr)
			}
		})
	}
}

func TestDBReadBoundsCoverTheShippedCatalog(t *testing.T) {
	manifests, err := filepath.Glob(filepath.Join("..", "..", "..", "packs", "*", "pack.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if len(manifests) == 0 {
		t.Fatal("no pack manifests found")
	}
	for _, manifest := range manifests {
		packDir := filepath.Dir(manifest)
		if err := validatePackDBReadBounds(mustLoadPackActionLintInput(t, packDir)); err != nil {
			t.Error(err)
		}
	}
}
