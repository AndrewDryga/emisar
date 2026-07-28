package devtool

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"go.yaml.in/yaml/v3"
)

// A shell pipeline exits with its LAST command's status, so `grep … | tail`
// reports success when the file is missing and the action is recorded as a
// successful read that found nothing. On the low, no-approval reads an operator
// or an LLM uses to check for errors, that empty output is a false all-clear.
//
// Authors guard the input first — see
// .agent/kb/rules/packs-pipelines-fail-on-source-errors.md, which also explains
// why `set -o pipefail` is the wrong fix (grep exits 1 on a legitimate
// no-match, so a clean log would become a failed action).
var pipelineSourceExemptActions = map[string]string{}

// Commands that open a path. A pipeline led by a local enumerator (ps, lsmod,
// ss, journalctl) has no meaningful failure to mask and is not checked here.
// awk and sort are deliberately absent: `awk '{print $1}'` reads as a path
// operand and they never lead a source-reading pipeline in this catalog.
var pipelineFileReaders = map[string]bool{
	"cat":  true,
	"du":   true,
	"find": true,
	"grep": true,
	"head": true,
	"tail": true,
	"zcat": true,
}

var pipelineSourceGuards = []string{
	"[ -r", "[ -f", "[ -d", "[ -e", "[ -s",
	"test -r", "test -f", "test -d", "test -e",
	"exit $status", "exit $?",
}

type packPipelineAction struct {
	ID        string `yaml:"id"`
	Execution struct {
		Command struct {
			Binary string   `yaml:"binary"`
			Argv   []string `yaml:"argv"`
		} `yaml:"command"`
	} `yaml:"execution"`
}

func validatePackPipelineFailures(packDir string) error {
	paths, err := filepath.Glob(filepath.Join(packDir, "actions", "*.yaml"))
	if err != nil {
		return err
	}
	sort.Strings(paths)

	var failures []string
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		var action packPipelineAction
		if err := yaml.Unmarshal(data, &action); err != nil {
			return fmt.Errorf("parse %s: %w", path, err)
		}
		if _, exempt := pipelineSourceExemptActions[action.ID]; exempt {
			continue
		}
		if action.Execution.Command.Binary != "/bin/sh" {
			continue
		}
		program, ok := shellDashCProgram(action.Execution.Command.Argv)
		if !ok {
			continue
		}
		if pipelineMasksSourceFailure(program) {
			failures = append(failures, action.ID)
		}
	}
	if len(failures) > 0 {
		return fmt.Errorf(
			"shell pipelines must fail when their source does; guard the input before piping into tail/head: %s",
			strings.Join(failures, ", "),
		)
	}
	return nil
}

func shellDashCProgram(argv []string) (string, bool) {
	for index, argument := range argv {
		if argument == "--" {
			return "", false
		}
		if len(argument) < 2 || argument[0] != '-' || argument[1] == '-' ||
			!strings.ContainsRune(argument[1:], 'c') {
			continue
		}
		if index+1 >= len(argv) {
			return "", false
		}
		return argv[index+1], true
	}
	return "", false
}

func pipelineMasksSourceFailure(program string) bool {
	if pipelineGuardsItsSource(program) {
		return false
	}
	for _, line := range strings.Split(program, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		index := firstPipeIndex(line)
		if index < 0 {
			continue
		}
		if pipelineSourceReadsPath(line[:index]) {
			return true
		}
	}
	return false
}

// firstPipeIndex finds the first real pipe, stepping over the `||` and `|&`
// operators and over anything inside quotes. `cat a || cat b` propagates its own
// failure and is not a pipeline, and the alternation in
// `grep -E '(a|b)' "$1" | tail` is regex syntax, not shell.
func firstPipeIndex(line string) int {
	return indexUnquoted(line, func(line string, index int) bool {
		if line[index] != '|' {
			return false
		}
		if index+1 < len(line) && (line[index+1] == '|' || line[index+1] == '&') {
			return false
		}
		return index == 0 || line[index-1] != '|'
	})
}

// lastUnquotedStatement returns the final `;`-separated statement, ignoring any
// separator inside quotes — `SP=$(python -c 'import site; print(x)'); du …`
// is one assignment followed by the command that matters.
func lastUnquotedStatement(segment string) string {
	start := 0
	for {
		index := indexUnquotedFrom(segment, start, func(line string, index int) bool {
			return line[index] == ';'
		})
		if index < 0 {
			return segment[start:]
		}
		start = index + 1
	}
}

func indexUnquoted(line string, match func(string, int) bool) int {
	return indexUnquotedFrom(line, 0, match)
}

// indexUnquotedFrom scans from offset, tracking single- and double-quote spans,
// and returns the first index at or after it where match reports true outside
// any quoted span.
func indexUnquotedFrom(line string, offset int, match func(string, int) bool) int {
	var quote byte
	for index := 0; index < len(line); index++ {
		character := line[index]
		switch {
		case quote == '\'':
			if character == '\'' {
				quote = 0
			}
			continue
		case quote == '"':
			if character == '\\' {
				index++
			} else if character == '"' {
				quote = 0
			}
			continue
		case character == '\'', character == '"':
			quote = character
			continue
		}
		if index >= offset && match(line, index) {
			return index
		}
	}
	return -1
}

func pipelineGuardsItsSource(program string) bool {
	for _, guard := range pipelineSourceGuards {
		if strings.Contains(program, guard) {
			return true
		}
	}
	return false
}

// pipelineSourceReadsPath reports whether the leading segment of a pipeline
// runs a file-reading command against a path operand.
func pipelineSourceReadsPath(segment string) bool {
	fields := strings.Fields(strings.TrimSpace(lastUnquotedStatement(segment)))

	for len(fields) > 0 && strings.Contains(fields[0], "=") &&
		!strings.HasPrefix(fields[0], "-") {
		fields = fields[1:]
	}
	if len(fields) == 0 || !pipelineFileReaders[fields[0]] {
		return false
	}
	for _, operand := range fields[1:] {
		if shellOperandIsPath(operand) {
			return true
		}
	}
	return false
}

func shellOperandIsPath(operand string) bool {
	unquoted := strings.Trim(operand, `"'`)
	switch {
	case strings.HasPrefix(unquoted, "/"):
		return true
	case strings.HasPrefix(unquoted, "$"), strings.HasPrefix(unquoted, "${"):
		return true
	default:
		return false
	}
}
