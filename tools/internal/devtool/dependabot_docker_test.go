package devtool

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Lanes shaped like the real ones: a docker lane with a plain directory, a
// one-segment glob and the two-segment glob the pack SUT subdirectories need,
// and a docker-compose lane for the root stack.
const dependabotDockerFixture = `version: 2
updates:
  - package-ecosystem: "gomod"
    directories: ["/runner"]
  - package-ecosystem: "docker"
    directories:
      - "/portal"
      - "/dev/runner/"
      - "/packs/*/test"
      - "/packs/*/test/*"
  - package-ecosystem: "docker-compose"
    directory: "/"
`

// Every exclusion must match a file, or the check reports it as stale, so each
// fixture carries one for each of them.
var dependabotDockerExcludedFixtures = []string{
	".agent/Dockerfile", "dev/compose.yml", "dev/review-compose.yml", "dev/test-packs/compose.yaml",
	"dev/test-packs/gcloud/Dockerfile", "packs/nginx/test/compose.yaml", "packs/docker/test/fixtures/worst-case-compose.yml",
}

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
	excluded := dependabotDockerExcludedFixtures

	for _, testCase := range []struct {
		name  string
		files []string
		want  string
	}{
		{
			name: "covered locations pass",
			files: []string{
				"docker-compose.yml",               // the docker-compose "/" root
				"portal/Dockerfile",                // a plain directory
				"dev/runner/Dockerfile",            // a glob written with a trailing slash
				"packs/nginx/test/Dockerfile",      // /packs/*/test
				"packs/snmp/test/snmpd/Dockerfile", // /packs/*/test/*
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
			want:  "stack/docker-compose.yaml: /stack matches no docker-compose directory",
		},
		{
			// The docker ecosystem reads no compose file, so a docker directory
			// does not carry one: this is how the root stack sat unbumped.
			name:  "a compose file in a docker directory is uncovered",
			files: []string{"portal/compose.yaml"},
			want:  "portal/compose.yaml: /portal matches no docker-compose directory",
		},
		{
			// The compose fetcher's pattern is unanchored, so a prefixed name is
			// a compose file too.
			name:  "a prefixed compose name is a compose file",
			files: []string{"dev/runner/review-compose.yml"},
			want:  "dev/runner/review-compose.yml: /dev/runner matches no docker-compose directory",
		},
		{
			name:  "a Dockerfile in the compose root is uncovered",
			files: []string{"Dockerfile"},
			want:  "Dockerfile: / matches no docker directory",
		},
		{
			// Dependabot parses no ignore file, so a directory holding only one needs no lane.
			name:  "a per-Dockerfile ignore file is not a build file",
			files: []string{".agent/Dockerfile.dockerignore", "portal/assets/Dockerfile.dockerignore"},
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
	var withoutGcloud []string
	for _, file := range excluded {
		if file != "dev/test-packs/gcloud/Dockerfile" {
			withoutGcloud = append(withoutGcloud, file)
		}
	}
	err := writeDependabotDockerFixtures(t, dependabotDockerFixture, withoutGcloud...).
		checkDependabotDockerCoverage()
	if err == nil || !strings.Contains(err.Error(), "dev/test-packs/gcloud/Dockerfile: excluded from the Dependabot lanes but no such build file exists") {
		t.Fatalf("stale exclusion not reported: %v", err)
	}

	// A config that stops listing either container lane fails loudly instead of
	// passing on an empty glob set, which would call every location uncovered.
	for _, lane := range []string{"docker", "docker-compose"} {
		other := map[string]string{"docker": "docker-compose", "docker-compose": "docker"}[lane]
		err = writeDependabotDockerFixtures(t, "version: 2\nupdates:\n  - package-ecosystem: \""+other+"\"\n    directory: \"/\"\n").
			checkDependabotDockerCoverage()
		if err == nil || !strings.Contains(err.Error(), "declares no package-ecosystem: "+lane+" directories") {
			t.Fatalf("missing %s lane not reported: %v", lane, err)
		}
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

func TestCheckDependabotDockerCoverageSkipsUnreadableDirectoriesOnlyInABox(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root can read a mode-000 directory")
	}
	app := writeDependabotDockerFixtures(t, dependabotDockerFixture, dependabotDockerExcludedFixtures...)
	hidden := filepath.Join(app.Root, "portal", ".agent", "secrets")
	if err := os.MkdirAll(hidden, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(hidden, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(hidden, 0o755) })

	t.Setenv("COOP_BOX", "")
	if err := app.checkDependabotDockerCoverage(); err == nil {
		t.Fatal("an unreadable directory outside a box must fail the walk")
	}

	t.Setenv("COOP_BOX", "1")
	if err := app.checkDependabotDockerCoverage(); err != nil {
		t.Fatalf("inside a box an unreadable stand-in must be skipped: %v", err)
	}
}
