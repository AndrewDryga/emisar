package devtool

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"go.yaml.in/yaml/v3"
)

var httpStatusReportingActions = map[string]bool{
	"net.http_headers": true,
	"net.http_probe":   true,
}

type packHTTPAction struct {
	ID        string `yaml:"id"`
	Execution struct {
		Command struct {
			Binary string   `yaml:"binary"`
			Argv   []string `yaml:"argv"`
		} `yaml:"command"`
		Script struct {
			Path string `yaml:"path"`
		} `yaml:"script"`
	} `yaml:"execution"`
}

func validatePackHTTPFailures(packDir string) error {
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
		var action packHTTPAction
		if err := yaml.Unmarshal(data, &action); err != nil {
			return fmt.Errorf("parse %s: %w", path, err)
		}
		if httpStatusReportingActions[action.ID] {
			continue
		}

		command := action.Execution.Command
		switch {
		case command.Binary == "curl":
			if !curlArgsFailHTTP(command.Argv) {
				failures = append(failures, action.ID)
			}
		case command.Binary == "/bin/sh":
			if curlSourceAcceptsHTTPFailures(strings.Join(command.Argv, "\n")) {
				failures = append(failures, action.ID)
			}
		case action.Execution.Script.Path != "":
			scriptPath := filepath.Join(packDir, filepath.Clean(action.Execution.Script.Path))
			script, err := os.ReadFile(scriptPath)
			if err != nil {
				return err
			}
			if curlSourceAcceptsHTTPFailures(string(script)) {
				failures = append(failures, action.ID)
			}
		}
	}
	if len(failures) > 0 {
		return fmt.Errorf(
			"curl-backed actions must fail on HTTP response errors: %s",
			strings.Join(failures, ", "),
		)
	}
	return nil
}

func curlSourceAcceptsHTTPFailures(source string) bool {
	invocations := curlInvocations(source)
	if len(invocations) == 1 && explicitlyChecksHTTPStatus(source) {
		return false
	}
	for _, invocation := range invocations {
		if !curlArgsFailHTTP(invocation) {
			return true
		}
	}
	return false
}

func curlInvocations(source string) [][]string {
	var invocations [][]string
	for _, line := range strings.Split(source, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		for offset := 0; offset < len(line); {
			index := strings.Index(line[offset:], "curl")
			if index < 0 {
				break
			}
			start := offset + index
			end := start + len("curl")
			offset = end
			if !shellWordBoundary(line, start-1) ||
				!shellWordBoundary(line, end) ||
				!shellCommandPosition(line[:start]) {
				continue
			}
			invocations = append(
				invocations,
				strings.Fields(shellCommandPrefix(line[end:])),
			)
		}
	}
	return invocations
}

func shellCommandPosition(prefix string) bool {
	prefix = strings.TrimSpace(prefix)
	if prefix == "" {
		return true
	}
	for _, operator := range []string{";", "|", "||", "&", "&&", "(", "$(", "`"} {
		if strings.HasSuffix(prefix, operator) {
			return true
		}
	}
	fields := strings.Fields(prefix)
	if len(fields) == 0 {
		return true
	}
	switch fields[len(fields)-1] {
	case "if", "elif", "then", "else", "do", "!", "{":
		return true
	default:
		return false
	}
}

func shellWordBoundary(value string, index int) bool {
	if index < 0 || index >= len(value) {
		return true
	}
	return strings.ContainsRune(" \t;|&()`$=", rune(value[index]))
}

func shellCommandPrefix(value string) string {
	if index := strings.IndexAny(value, ";|&"); index >= 0 {
		return value[:index]
	}
	return value
}

func curlArgsFailHTTP(args []string) bool {
	for _, argument := range args {
		argument = strings.Trim(argument, `"'`)
		switch {
		case argument == "--fail", argument == "--fail-with-body":
			return true
		case strings.HasPrefix(argument, "-") &&
			!strings.HasPrefix(argument, "--") &&
			strings.Contains(argument[1:], "f"):
			return true
		}
	}
	return false
}

func explicitlyChecksHTTPStatus(source string) bool {
	return strings.Contains(source, "%{http_code}") &&
		strings.Contains(source, `case "$code" in`) &&
		strings.Contains(source, "2*)")
}
