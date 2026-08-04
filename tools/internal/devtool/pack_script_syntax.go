package devtool

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"go.yaml.in/yaml/v3"
)

// A packaged script is inert text until a runner executes it, so a stray quote
// or an unclosed `if` validates, hashes, publishes and is trusted — and only
// then fails on the host, at dispatch, after the operator approved the action.
// The interpreter's own `-n` mode parses the whole file without running a byte
// of it, which is the same answer the runner's shell will give.
//
// A blank interpreter defaults to /bin/sh here exactly as it does in
// runner/internal/executor/script.go, so the lint parses what will actually run.
var packScriptParsers = map[string]bool{
	"/bin/sh":   true,
	"/bin/bash": true,
}

type packScriptAction struct {
	ID        string `yaml:"id"`
	Execution struct {
		Script struct {
			Path        string `yaml:"path"`
			Interpreter string `yaml:"interpreter"`
		} `yaml:"script"`
	} `yaml:"execution"`
}

// packScriptRef is one thing to parse. The catalog's 320 script actions reuse
// 49 files, so the pair is what gets parsed once rather than the action.
type packScriptRef struct {
	interpreter string
	path        string
}

func validatePackScriptSyntax(ctx context.Context, packDir string) error {
	paths, err := filepath.Glob(filepath.Join(packDir, "actions", "*.yaml"))
	if err != nil {
		return err
	}
	sort.Strings(paths)

	scripts := make(map[packScriptRef][]string)
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		var action packScriptAction
		if err := yaml.Unmarshal(data, &action); err != nil {
			return fmt.Errorf("parse %s: %w", path, err)
		}
		script := action.Execution.Script
		if script.Path == "" {
			continue
		}
		interpreter := script.Interpreter
		if interpreter == "" {
			interpreter = "/bin/sh"
		}
		// Another language's parser is another language's job; this check is
		// shell syntax only.
		if !packScriptParsers[interpreter] {
			continue
		}
		ref := packScriptRef{interpreter: interpreter, path: filepath.Clean(script.Path)}
		scripts[ref] = append(scripts[ref], action.ID)
	}

	refs := make([]packScriptRef, 0, len(scripts))
	for ref := range scripts {
		refs = append(refs, ref)
	}
	sort.Slice(refs, func(i, j int) bool {
		if refs[i].path != refs[j].path {
			return refs[i].path < refs[j].path
		}
		return refs[i].interpreter < refs[j].interpreter
	})

	var failures []string
	for _, ref := range refs {
		// The shell's own diagnostic names the line and what it was looking for,
		// so it is carried in the error rather than printed: this runs per pack
		// inside a gate that already owns what reaches the operator.
		command := exec.CommandContext(ctx, ref.interpreter, "-n", filepath.Join(packDir, ref.path))
		output, err := command.CombinedOutput()
		if err == nil {
			continue
		}
		// A canceled gate kills the parser, which also exits non-zero. That is
		// the caller leaving, not a malformed script.
		if ctx.Err() != nil {
			return ctx.Err()
		}
		var exit *exec.ExitError
		if !errors.As(err, &exit) {
			return fmt.Errorf("parse %s with %s: %w", ref.path, ref.interpreter, err)
		}
		failures = append(failures, fmt.Sprintf("%s %s (%s): %s",
			ref.interpreter, ref.path, packScriptActionContext(scripts[ref]),
			strings.TrimSpace(string(output))))
	}
	if len(failures) > 0 {
		return fmt.Errorf(
			"packaged scripts must parse under their declared interpreter: %s",
			strings.Join(failures, "; "),
		)
	}
	return nil
}

// packScriptActionContext names a referencing action, because a shared script
// path alone does not say which dispatch breaks.
func packScriptActionContext(ids []string) string {
	sort.Strings(ids)
	if len(ids) == 1 {
		return ids[0]
	}
	return fmt.Sprintf("%s and %d more", ids[0], len(ids)-1)
}
