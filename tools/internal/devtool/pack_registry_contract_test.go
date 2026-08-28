package devtool

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCheckPackRegistryPointerContract(t *testing.T) {
	tests := []struct {
		name     string
		contract string
		manifest string
		wantErr  string
	}{
		{
			name:     "same paths in different order",
			contract: `["packs.json","v1/catalog.json"]`,
			manifest: `{"objects":[{"path":"v1/catalog.json","immutable":false},{"path":"v1/packs/a.tar.gz","immutable":true},{"path":"packs.json","immutable":false}]}`,
		},
		{
			name:     "new manifest alias missing from IAM",
			contract: `["v1/catalog.json","v1/suggest.json"]`,
			manifest: `{"objects":[{"path":"v1/catalog.json","immutable":false},{"path":"v1/suggest.json","immutable":false},{"path":"packs.json","immutable":false},{"path":"packs/suggest.json","immutable":false}]}`,
			wantErr:  "packs.json",
		},
		{
			name:     "IAM path not emitted by manifest",
			contract: `["packs.json","unused.json"]`,
			manifest: `{"objects":[{"path":"packs.json","immutable":false}]}`,
			wantErr:  "unused.json",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			root := t.TempDir()
			infraDir := filepath.Join(root, "infra")
			if err := os.MkdirAll(infraDir, 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(infraDir, "pack_registry_mutable_pointers.json"), []byte(test.contract), 0o644); err != nil {
				t.Fatal(err)
			}
			manifestPath := filepath.Join(root, "manifest.json")
			if err := os.WriteFile(manifestPath, []byte(test.manifest), 0o644); err != nil {
				t.Fatal(err)
			}

			err := checkPackRegistryPointerContract(root, manifestPath)
			if test.wantErr == "" {
				if err != nil {
					t.Fatalf("matching contract failed: %v", err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), test.wantErr) {
				t.Fatalf("error = %v, want containing %q", err, test.wantErr)
			}
		})
	}
}
