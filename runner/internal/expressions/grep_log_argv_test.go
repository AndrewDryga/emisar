package expressions

import (
	"os"
	"path/filepath"
	"testing"

	"gopkg.in/yaml.v3"
)

// TestGrepLogArgv_LeadingDashPatternStaysAPattern is a regression guard for
// finding B1: the linux.grep_log action rendered `grep -E -n -m N {{pattern}}
// {{file}}` with no `-e`/`--`, so a hostile pattern of "-r" reached grep as the
// recursive flag — escalating a scoped /var/log read into an arbitrary-host
// content dump. The fix binds the pattern with `-e` and ends option parsing
// with `--` before the file operand. This loads the REAL pack action (so a
// revert of the YAML fails here) and asserts, through the actual RenderArgv
// engine, that a leading-dash pattern lands as grep's pattern operand and the
// file lands after `--` — never as a flag.
func TestGrepLogArgv_LeadingDashPatternStaysAPattern(t *testing.T) {
	// runner/internal/expressions -> repo root is three levels up.
	path := filepath.Join("..", "..", "..", "packs", "linux-core", "actions", "grep_log.yaml")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read grep_log action: %v", err)
	}
	var spec struct {
		Execution struct {
			Command struct {
				Argv []string `yaml:"argv"`
			} `yaml:"command"`
		} `yaml:"execution"`
	}
	if err := yaml.Unmarshal(raw, &spec); err != nil {
		t.Fatalf("parse grep_log action: %v", err)
	}

	const hostilePattern = "-r" // the recursive flag, if it reaches grep as one
	const file = "/var/log/nginx/access.log"
	out, err := RenderArgv(spec.Execution.Command.Argv, map[string]any{
		"max_lines": 2000,
		"pattern":   hostilePattern,
		"file":      file,
	})
	if err != nil {
		t.Fatalf("RenderArgv: %v", err)
	}

	patIdx := indexOf(out, hostilePattern)
	if patIdx < 1 || out[patIdx-1] != "-e" {
		t.Fatalf("pattern %q must be bound by -e so a leading dash is a literal pattern, got argv: %#v", hostilePattern, out)
	}
	fileIdx := indexOf(out, file)
	if fileIdx < 1 || out[fileIdx-1] != "--" {
		t.Fatalf("file operand must follow -- so it can't be read as a flag, got argv: %#v", out)
	}
}

func indexOf(ss []string, want string) int {
	for i, s := range ss {
		if s == want {
			return i
		}
	}
	return -1
}
