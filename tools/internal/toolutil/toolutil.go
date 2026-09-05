// Package toolutil holds the few primitives more than one tooling package
// needs and the standard library does not provide, so each has one definition
// instead of a copy per consumer that can drift.
package toolutil

import (
	"bytes"
	"os"
	"sort"
	"strings"
)

// MergedEnv renders the current process environment with overrides applied, in
// sorted KEY=VALUE form for exec.Cmd.Env. Sorting keeps a child's environment
// reproducible across runs so a failing command can be replayed verbatim.
func MergedEnv(overrides map[string]string) []string {
	values := make(map[string]string)
	for _, entry := range os.Environ() {
		key, value, found := strings.Cut(entry, "=")
		if found {
			values[key] = value
		}
	}
	for key, value := range overrides {
		values[key] = value
	}
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	env := make([]string, 0, len(keys))
	for _, key := range keys {
		env = append(env, key+"="+values[key])
	}
	return env
}

// NULFields splits the output of a `git -z` command into its records. Git
// terminates rather than separates, so the trailing empty field is dropped
// along with any other empty record.
func NULFields(data []byte) []string {
	fields := bytes.Split(data, []byte{0})
	values := make([]string, 0, len(fields))
	for _, field := range fields {
		if len(field) != 0 {
			values = append(values, string(field))
		}
	}
	return values
}

// HasAnyPrefix reports whether value starts with any of the prefixes.
func HasAnyPrefix(value string, prefixes ...string) bool {
	for _, prefix := range prefixes {
		if strings.HasPrefix(value, prefix) {
			return true
		}
	}
	return false
}
