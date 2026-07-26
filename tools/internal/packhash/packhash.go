// Package packhash verifies the two pack hashes shared by the Go runner and
// the Portal's Elixir registry implementation.
package packhash

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

const goldenPath = "portal/apps/emisar_web/test/emisar_web/packs_test.exs"

var (
	hashLine   = regexp.MustCompile(`sha256:[0-9a-f]{64}`)
	hashOutput = regexp.MustCompile(`(?m)^hash: (sha256:[0-9a-f]{64})$`)
)

// ErrUnavailable means the runner validator is not built. Commit hooks may
// fail open on this condition; explicit pack checks should report it.
var ErrUnavailable = errors.New("runner pack validator is unavailable")

type golden struct {
	pack  string
	start int
	end   int
	hash  string
}

func parseGoldens(data []byte) (map[string]golden, error) {
	lines := bytes.SplitAfter(data, []byte("\n"))
	offset := 0
	pending := ""
	found := make(map[string]golden)
	for _, line := range lines {
		text := string(line)
		for _, pack := range []string{"redis", "cassandra"} {
			if strings.Contains(text, `get("`+pack+`").content_hash ==`) {
				pending = pack
			}
		}
		if pending != "" {
			location := hashLine.FindIndex(line)
			if location != nil {
				found[pending] = golden{
					pack: pending, start: offset + location[0], end: offset + location[1],
					hash: string(line[location[0]:location[1]]),
				}
				pending = ""
			}
		}
		offset += len(line)
	}
	for _, pack := range []string{"redis", "cassandra"} {
		if _, ok := found[pack]; !ok {
			return nil, fmt.Errorf("%s does not contain the %s content hash golden", goldenPath, pack)
		}
	}
	return found, nil
}

func validator(root, configured string) (string, error) {
	if configured != "" {
		if info, err := os.Stat(configured); err == nil && !info.IsDir() {
			return configured, nil
		}
		return "", fmt.Errorf("%w: %s", ErrUnavailable, configured)
	}
	local := filepath.Join(root, "bin", "emisar")
	if info, err := os.Stat(local); err == nil && !info.IsDir() {
		return local, nil
	}
	path, err := exec.LookPath("emisar")
	if err != nil {
		return "", fmt.Errorf("%w: run go -C runner build -o ../bin/emisar . to build bin/emisar", ErrUnavailable)
	}
	return path, nil
}

func currentHash(root, binary, pack string) (string, error) {
	command := exec.Command(binary, "pack", "validate", filepath.Join(root, "packs", pack))
	command.Dir = root
	output, err := command.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("validating %s: %w\n%s", pack, err, output)
	}
	match := hashOutput.FindSubmatch(output)
	if match == nil {
		return "", fmt.Errorf("validator returned no hash for %s:\n%s", pack, output)
	}
	return string(match[1]), nil
}

// Check verifies or rewrites the Portal hash goldens.
func Check(root, configuredBinary string, write bool, out io.Writer) error {
	path := filepath.Join(root, filepath.FromSlash(goldenPath))
	data, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("reading %s: %w", goldenPath, err)
	}
	goldens, err := parseGoldens(data)
	if err != nil {
		return err
	}
	binary, err := validator(root, configuredBinary)
	if err != nil {
		return err
	}

	current := make(map[string]string, 2)
	for _, pack := range []string{"redis", "cassandra"} {
		current[pack], err = currentHash(root, binary, pack)
		if err != nil {
			return err
		}
	}

	if write {
		ordered := []golden{goldens["redis"], goldens["cassandra"]}
		if ordered[0].start > ordered[1].start {
			ordered[0], ordered[1] = ordered[1], ordered[0]
		}
		var rewritten bytes.Buffer
		cursor := 0
		for _, entry := range ordered {
			rewritten.Write(data[cursor:entry.start])
			rewritten.WriteString(current[entry.pack])
			cursor = entry.end
		}
		rewritten.Write(data[cursor:])
		if err := os.WriteFile(path, rewritten.Bytes(), 0o644); err != nil {
			return fmt.Errorf("writing %s: %w", goldenPath, err)
		}
		fmt.Fprintf(out, "refreshed %s (redis=%s cassandra=%s)\n", goldenPath, current["redis"], current["cassandra"])
		fmt.Fprintln(out, "run: (cd portal/apps/emisar_web && mix test test/emisar_web/packs_test.exs)")
		return nil
	}

	var stale []string
	for _, pack := range []string{"redis", "cassandra"} {
		if current[pack] != goldens[pack].hash {
			stale = append(stale, fmt.Sprintf("  %s: golden %s != actual %s",
				pack, goldens[pack].hash, current[pack]))
		}
	}
	if len(stale) == 0 {
		return nil
	}
	return fmt.Errorf("cross-implementation hash golden is stale in %s:\n%s\nrun: ./run pack hashes --write",
		goldenPath, strings.Join(stale, "\n"))
}
