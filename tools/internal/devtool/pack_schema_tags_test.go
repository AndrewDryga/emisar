package devtool

import (
	"os"
	"path/filepath"
	"regexp"
	"testing"
)

// The pack lints in this package unmarshal into small structs that name a
// handful of pack.yaml / action YAML keys — not the canonical
// runner/pkg/{packspec,actionspec} types, because tools does not depend on the
// runner module. That leaves a silent failure: rename a field in the runner
// and these lints keep compiling, unmarshal the zero value, and stop linting.
// This test reads the canonical sources and fails when any key the lints rely
// on is no longer declared there.
func TestPackLintsUseTheCanonicalSchemaKeys(t *testing.T) {
	for _, tc := range []struct {
		source string
		keys   []string
	}{
		{"runner/pkg/packspec/pack.go", []string{"actions", "requires", "binaries"}},
		{"runner/pkg/actionspec/action.go", []string{"id", "execution", "script", "path", "interpreter"}},
	} {
		data, err := os.ReadFile(filepath.Join("..", "..", "..", tc.source))
		if err != nil {
			t.Fatalf("read canonical schema: %v", err)
		}
		for _, key := range tc.keys {
			if !regexp.MustCompile("`yaml:\"" + key + "[\",]").Match(data) {
				t.Errorf("%s no longer declares a field tagged yaml:%q; packActionLintManifest / packScriptAction in this package read that key", tc.source, key)
			}
		}
	}
}
