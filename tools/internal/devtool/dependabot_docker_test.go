package devtool

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A docker lane shaped like the real one: a plain directory, a one-segment glob,
// and the two-segment glob the pack SUT subdirectories need.
const dependabotDockerFixture = `version: 2
updates:
  - package-ecosystem: "gomod"
    directories: ["/runner"]
  - package-ecosystem: "docker"
    directories:
      - "/"
      - "/portal"
      - "/dev/runner/"
      - "/packs/*/test"
      - "/packs/*/test/*"
`

func writeDependabotDockerFixtures(t *testing.T, config string, files ...string) *App {
	t.Helper()
	root := t.TempDir()
	for _, relative := range append([]string{".github/dependabot.yml"}, files...) {
		body := "FROM scratch\n"
		if relative == ".github/dependabot.yml" {
			body = config
		}
		full := filepath.Join(root, filepath.FromSlash(relative))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return New(root, strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{})
}

func TestCheckDependabotDockerCoverage(t *testing.T) {
	// Every exclusion must exist, or the check reports it as stale, so each case
	// carries all three of them.
	excluded := []string{".agent/Dockerfile", "dev/compose.yml", "dev/test-packs/gcloud/Dockerfile"}

	for _, testCase := range []struct {
		name  string
		files []string
		want  string
	}{
		{
			name: "covered locations pass",
			files: []string{
				"docker-compose.yml",            // the "/" root
				"portal/Dockerfile",             // a plain directory
				"dev/runner/Dockerfile",         // a glob written with a trailing slash
				"packs/nginx/test/compose.yaml", // /packs/*/test
				"packs/nginx/test/Dockerfile",
				"packs/snmp/test/snmpd/Dockerfile",        // /packs/*/test/*
				"packs/docker/test/fixtures/compose.yaml", // still one segment deep
			},
		},
		{
			name:  "excluded locations pass without a glob",
			files: nil,
		},
		{
			// The drift this check was added for: a build file in a fresh
			// subdirectory of an already-listed directory. Docker directories are
			// not recursive, so "/portal" does not carry it.
			name:  "a new subdirectory of a listed directory is uncovered",
			files: []string{"portal/assets/Dockerfile"},
			want:  "portal/assets/Dockerfile: /portal/assets matches no docker directory",
		},
		{
			// One segment too deep for "/packs/*/test/*".
			name:  "a location past the deepest glob is uncovered",
			files: []string{"packs/snmp/test/snmpd/conf/Dockerfile"},
			want:  "packs/snmp/test/snmpd/conf/Dockerfile: /packs/snmp/test/snmpd/conf matches no docker directory",
		},
		{
			name:  "a compose file in a new top-level directory is uncovered",
			files: []string{"stack/docker-compose.yaml"},
			want:  "stack/docker-compose.yaml: /stack matches no docker directory",
		},
		{
			name:  "a suffixed Dockerfile is enumerated like any other",
			files: []string{"dev/test-host-access/Dockerfile.debian"},
			want:  "dev/test-host-access/Dockerfile.debian: /dev/test-host-access matches no docker directory",
		},
		{
			// Fetched dependencies, their build output, and archived task folders
			// hold build files nobody publishes.
			name: "skipped trees are not enumerated",
			files: []string{
				"portal/deps/bandit/Dockerfile",
				"portal/_build/dev/Dockerfile",
				"portal/assets/node_modules/x/Dockerfile",
				"portal/.agent/tasks/99_done/old/recipe/Dockerfile",
				".agent/tasks/00_todo/new/compose.yaml",
			},
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			app := writeDependabotDockerFixtures(t, dependabotDockerFixture, append(testCase.files, excluded...)...)
			err := app.checkDependabotDockerCoverage()
			switch {
			case testCase.want == "" && err != nil:
				t.Fatalf("expected coverage to pass: %v", err)
			case testCase.want != "" && (err == nil || !strings.Contains(err.Error(), testCase.want)):
				t.Fatalf("expected %q to be reported, got: %v", testCase.want, err)
			}
		})
	}

	// An exclusion whose file is gone would silently cover the path if it came
	// back, so it fails rather than lingering.
	err := writeDependabotDockerFixtures(t, dependabotDockerFixture, ".agent/Dockerfile", "dev/compose.yml").
		checkDependabotDockerCoverage()
	if err == nil || !strings.Contains(err.Error(), "dev/test-packs/gcloud/Dockerfile: excluded from the docker lane but no such build file exists") {
		t.Fatalf("stale exclusion not reported: %v", err)
	}

	// A lane that stops listing docker fails loudly instead of passing on an
	// empty glob set, which would call every location uncovered.
	err = writeDependabotDockerFixtures(t, "version: 2\nupdates:\n  - package-ecosystem: \"gomod\"\n    directory: \"/runner\"\n").
		checkDependabotDockerCoverage()
	if err == nil || !strings.Contains(err.Error(), "declares no package-ecosystem: docker directories") {
		t.Fatalf("missing docker lane not reported: %v", err)
	}

	// A pathspec that selects nothing is the shape of a check that stopped
	// checking, so an empty repository is a failure, not a pass.
	err = writeDependabotDockerFixtures(t, dependabotDockerFixture).checkDependabotDockerCoverage()
	if err == nil || !strings.Contains(err.Error(), "no Dockerfile or compose file was found") {
		t.Fatalf("empty enumeration not reported: %v", err)
	}
}

// The real tree is the case that matters: the committed lane and exclusion list
// must actually agree with the repository the gate runs against.
func TestCheckDependabotDockerCoverageOnRepository(t *testing.T) {
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	app := New(root, strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{})
	if err := app.checkDependabotDockerCoverage(); err != nil {
		t.Fatal(err)
	}
}
