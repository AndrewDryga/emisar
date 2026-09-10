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
	"sort"
	"strings"
)

const goldenPath = "portal/apps/emisar/test/emisar/catalog/published_registry_test.exs"

// GoldenPacks are the packs whose content hash the Portal test pins byte for
// byte: redis (exec-only actions) and cassandra (a script-kind action) between
// them exercise every hash input. Every loop here and the `pack check` route
// in devtool read this one list.
var GoldenPacks = []string{"redis", "cassandra"}

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
	distance := 0
	found := make(map[string]golden)
	for _, line := range lines {
		text := string(line)
		for _, pack := range GoldenPacks {
			if strings.Contains(text, `get("`+pack+`").content_hash ==`) {
				pending = pack
				distance = 0
			}
		}
		if pending != "" {
			location := hashLine.FindIndex(line)
			switch {
			case location != nil:
				found[pending] = golden{
					pack: pending, start: offset + location[0], end: offset + location[1],
					hash: string(line[location[0]:location[1]]),
				}
				pending = ""
				distance = 0
			case distance >= 2:
				// The golden sits on the assertion line or the one after it.
				// Searching further meant that if the assertion's own hash moved
				// or was deleted, the next `sha256:` anywhere below it was claimed
				// instead — and `--write` would rewrite those bytes.
				pending = ""
				distance = 0
			default:
				distance++
			}
		}
		offset += len(line)
	}
	for _, pack := range GoldenPacks {
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
	// This checkout's binary or nothing. The golden exists to prove that the Go
	// runner and the Elixir PublishedRegistry in THIS tree hash a pack
	// identically, so an `emisar` picked up from PATH — a developer's installed
	// product runner, some other version entirely — cannot answer that question,
	// and `--write` would record its answer as ours.
	local := filepath.Join(root, "bin", "emisar")
	if info, err := os.Stat(local); err == nil && !info.IsDir() {
		return local, nil
	}
	return "", fmt.Errorf("%w: run go -C runner build -o ../bin/emisar . to build bin/emisar", ErrUnavailable)
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

	current := make(map[string]string, len(GoldenPacks))
	for _, pack := range GoldenPacks {
		current[pack], err = currentHash(root, binary, pack)
		if err != nil {
			return err
		}
	}

	if write {
		ordered := make([]golden, 0, len(GoldenPacks))
		for _, pack := range GoldenPacks {
			ordered = append(ordered, goldens[pack])
		}
		sort.Slice(ordered, func(i, j int) bool { return ordered[i].start < ordered[j].start })
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
		refreshed := make([]string, 0, len(GoldenPacks))
		for _, pack := range GoldenPacks {
			refreshed = append(refreshed, pack+"="+current[pack])
		}
		fmt.Fprintf(out, "refreshed %s (%s)\n", goldenPath, strings.Join(refreshed, " "))
		fmt.Fprintln(out, "run: (cd portal/apps/emisar && mix test test/emisar/catalog/published_registry_test.exs)")
		return nil
	}

	var stale []string
	for _, pack := range GoldenPacks {
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
