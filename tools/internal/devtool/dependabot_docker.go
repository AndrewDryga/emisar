package devtool

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"go.yaml.in/yaml/v3"
)

// The build locations that stay outside the Dependabot container lanes on
// purpose, each with the reason .github/dependabot.yml states in prose. This list
// is the mechanical half of that comment: Dependabot directories are not
// recursive, so a Dockerfile or compose file in a fresh subdirectory otherwise
// leaves the lane silently — dev/test-packs/gcloud/Dockerfile did exactly that
// and was only caught by a review board. Adding a location here is a decision to
// never get a bump PR for it, so state why nothing is lost. A key is a
// path.Match pattern over the repository-relative path.
var dependabotDockerExclusions = map[string]string{
	".agent/Dockerfile":                "builds FROM an ARG base image that is the operator's coop box, which Dependabot cannot resolve",
	"dev/compose.yml":                  "mirrors the root docker-compose.yml Postgres and Keycloak pins byte for byte, together with dev/review-compose.yml; Dependabot opens PRs per directory, so listing \"/dev\" would move one mirror off the reference on its own and fail the shared service image pins phase",
	"dev/review-compose.yml":           "mirrors the root docker-compose.yml Postgres pin byte for byte and travels with dev/compose.yml, whose reason covers both mirrors",
	"dev/test-packs/compose.yaml":      "runs the locally built runner image PACKTEST_RUNNER_IMAGE names, which no registry publishes",
	"dev/test-packs/gcloud/Dockerfile": "builds FROM an ARG gcloud version owned by each packs/gcp-*/test/cases.yaml, which the pack gate makes compose default PACKTEST_VERSION to",
	"packs/*/test/compose.yaml":        "a pack's primary SUT image defaults PACKTEST_VERSION to the version its test/cases.yaml matrix owns, which the pack gate enforces, so a compose-only bump would fail that gate",
	"packs/docker/test/fixtures/*":     "inputs to the docker pack's compose actions under test, not a stack anyone runs",
}

// Trees that hold build files nobody publishes: fetched dependencies, their
// vendored build output, the pack harness's ignored per-run reports (which keep
// the rendered compose file of each hostile run), and the archived task folders
// under .agent/tasks (one of which carries a devcontainer Dockerfile).
func skipDependabotDockerDir(rel string) bool {
	if rel == "portal/deps" || rel == "dev/test-packs/reports" {
		return true
	}
	switch path.Base(rel) {
	case ".git", "node_modules", "_build":
		return true
	case "tasks":
		return path.Base(path.Dir(rel)) == ".agent"
	}
	return false
}

// Dependabot's docker-compose fetcher keeps file names matching this, unanchored
// (dependabot-core docker/lib/dependabot/docker_compose/file_fetcher.rb). The
// docker ecosystem reads Dockerfiles, and YAML only in Kubernetes or Helm
// shapes, so a compose file is bumped only from a docker-compose directory.
var dependabotComposeFile = regexp.MustCompile(`(?i)(docker-)?compose(-\w+)?(\.[\w-]+)?\.ya?ml`)

// dependabotLane is the package-ecosystem that reads a build file with this
// name, or "" when neither container ecosystem reads it.
func dependabotLane(name string) string {
	if dependabotComposeFile.MatchString(name) {
		return "docker-compose"
	}
	// A per-Dockerfile ignore file (Dockerfile.dockerignore) shares the prefix but is not a build file.
	if strings.HasSuffix(name, ".dockerignore") {
		return ""
	}
	if strings.HasPrefix(name, "Dockerfile") || strings.HasSuffix(name, ".Dockerfile") {
		return "docker"
	}
	return ""
}

// The `directories` (or `directory`) of each container ecosystem in
// .github/dependabot.yml, keyed by package-ecosystem.
func (a *App) dependabotDockerDirectories() (map[string][]string, error) {
	relative := filepath.Join(".github", "dependabot.yml")
	data, err := os.ReadFile(filepath.Join(a.Root, relative))
	if err != nil {
		return nil, err
	}
	var config struct {
		Updates []struct {
			Ecosystem   string   `yaml:"package-ecosystem"`
			Directory   string   `yaml:"directory"`
			Directories []string `yaml:"directories"`
		} `yaml:"updates"`
	}
	if err := yaml.Unmarshal(data, &config); err != nil {
		return nil, fmt.Errorf("%s: %w", relative, err)
	}
	lanes := map[string][]string{}
	for _, update := range config.Updates {
		if update.Ecosystem != "docker" && update.Ecosystem != "docker-compose" {
			continue
		}
		if update.Directory != "" {
			lanes[update.Ecosystem] = append(lanes[update.Ecosystem], update.Directory)
		}
		lanes[update.Ecosystem] = append(lanes[update.Ecosystem], update.Directories...)
	}
	for _, ecosystem := range []string{"docker", "docker-compose"} {
		if len(lanes[ecosystem]) == 0 {
			return nil, fmt.Errorf("%s declares no package-ecosystem: %s directories", relative, ecosystem)
		}
		for i, glob := range lanes[ecosystem] {
			// "/dev/runner/" and "/dev/runner" name the same directory; "/" is itself.
			if trimmed := strings.TrimSuffix(glob, "/"); trimmed != "" {
				lanes[ecosystem][i] = trimmed
			}
		}
	}
	return lanes, nil
}

func (a *App) checkDependabotDockerCoverage() error {
	lanes, err := a.dependabotDockerDirectories()
	if err != nil {
		return err
	}
	var uncovered []string
	found := 0
	claimed := map[string]bool{}
	walkErr := filepath.WalkDir(a.Root, func(full string, entry fs.DirEntry, err error) error {
		if err != nil {
			// Inside a Coop box, secret-shaped paths are unreadable stand-ins for the real
			// ones; nothing under them is this repository's to check.
			if errors.Is(err, fs.ErrPermission) && os.Getenv("COOP_BOX") != "" {
				if entry != nil && entry.IsDir() {
					return fs.SkipDir
				}
				return nil
			}
			return err
		}
		relative, err := filepath.Rel(a.Root, full)
		if err != nil {
			return err
		}
		relative = filepath.ToSlash(relative)
		if entry.IsDir() {
			if relative != "." && skipDependabotDockerDir(relative) {
				return fs.SkipDir
			}
			return nil
		}
		lane := dependabotLane(entry.Name())
		if lane == "" {
			return nil
		}
		found++
		excluded := false
		for pattern := range dependabotDockerExclusions {
			if matched, _ := path.Match(pattern, relative); matched {
				claimed[pattern], excluded = true, true
			}
		}
		if excluded {
			return nil
		}
		// Dependabot directories are literal paths from the repository root, with
		// `*` matching one segment — the lane already relies on that for
		// "/packs/*/test".
		directory := "/" + path.Dir(relative)
		if directory == "/." {
			directory = "/"
		}
		for _, glob := range lanes[lane] {
			matched, err := path.Match(glob, directory)
			if err != nil {
				return fmt.Errorf(".github/dependabot.yml: %s directory %q is not a valid pattern: %w", lane, glob, err)
			}
			if matched {
				return nil
			}
		}
		uncovered = append(uncovered, fmt.Sprintf("%s: %s matches no %s directory", relative, directory, lane))
		return nil
	})
	if walkErr != nil {
		return walkErr
	}
	if found == 0 {
		return fmt.Errorf("no Dockerfile or compose file was found under %s", a.Root)
	}
	var problems []string
	problems = append(problems, uncovered...)
	// A left-behind exclusion is worse than a missing one: the path could come
	// back uncovered and stay silently outside the lane.
	for relative := range dependabotDockerExclusions {
		if !claimed[relative] {
			problems = append(problems, fmt.Sprintf("%s: excluded from the Dependabot lanes but no such build file exists", relative))
		}
	}
	if len(problems) > 0 {
		sort.Strings(problems)
		return fmt.Errorf("every Dockerfile must be in the .github/dependabot.yml docker lane and every compose file in its docker-compose lane, "+
			"or in dependabotDockerExclusions with a reason:\n  %s", strings.Join(problems, "\n  "))
	}
	fmt.Fprintf(a.Out, "verified: all %d Dockerfile/compose locations are covered by the Dependabot docker or docker-compose lane or excluded with a reason\n", found)
	return nil
}
