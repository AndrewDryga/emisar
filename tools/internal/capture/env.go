package capture

import (
	"bufio"
	"fmt"
	"os"
	"strings"
)

// ReadEnv loads a rig's credentials file and lets the process environment win
// for the keys in overrides — the tunnel URL, a per-run SCIM token, an app id
// minted this session. Those belong to the moment, not to a credentials file
// that outlives it.
//
// One parser because four rigs had hand-written their own and the copies had
// drifted three ways: only two stripped quotes from a value, only one treated a
// line with no `=` as an error, and the process-environment override was split
// between os.Getenv (an empty value cannot override) and os.LookupEnv (an empty
// value overrides with ""). Each rig still names its own override keys, which
// is the part that genuinely differs.
func ReadEnv(path string, overrides ...string) (map[string]string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	env := map[string]string{}
	scanner := bufio.NewScanner(file)
	for line := 1; scanner.Scan(); line++ {
		text := strings.TrimSpace(scanner.Text())
		if text == "" || strings.HasPrefix(text, "#") {
			continue
		}
		key, value, found := strings.Cut(text, "=")
		if !found {
			return nil, fmt.Errorf("%s:%d: expected KEY=VALUE, got %q", path, line, text)
		}
		env[strings.TrimSpace(key)] = strings.Trim(strings.TrimSpace(value), `'"`)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}

	// A key set to the empty string in the process environment is a deliberate
	// blank, so LookupEnv rather than Getenv: the rigs disagreed on this, and
	// the difference decides whether an exported-but-empty value clears the
	// file's credential or is silently ignored.
	for _, key := range overrides {
		if value, present := os.LookupEnv(key); present {
			env[key] = value
		}
	}
	return env, nil
}
