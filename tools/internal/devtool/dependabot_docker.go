package devtool

import (
	"fmt"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"

	"go.yaml.in/yaml/v3"
)

// The build locations that stay outside the Dependabot docker lane on purpose,
// each with the reason .github/dependabot.yml states in prose. This list is the
// mechanical half of that comment: docker directories are not recursive, so a
// Dockerfile or compose file in a fresh subdirectory otherwise leaves the lane
// silently — dev/test-packs/gcloud/Dockerfile did exactly that and was only
// caught by a review board. Adding a location here is a decision to never get a
// bump PR for it, so state why nothing is lost.
//
// dev/review-compose.yml is the fourth file the dependabot.yml comment names,
// but it is not enumerated below: Dependabot's docker ecosystem does not
// recognise that file name, so it was never in the lane to leave. It travels
// with dev/compose.yml, whose reason covers both mirrors.
var dependabotDockerExclusions = map[string]string{
	".agent/Dockerfile":                "builds FROM an ARG base image that is the operator's coop box, which Dependabot cannot resolve",
	"dev/compose.yml":                  "mirrors the root docker-compose.yml Postgres and Keycloak pins byte for byte, together with dev/review-compose.yml; Dependabot opens PRs per directory, so listing \"/dev\" would move one mirror off the reference on its own and fail the shared service image pins phase",
	"dev/test-packs/gcloud/Dockerfile": "builds FROM an ARG gcloud version owned by each packs/gcp-*/test/cases.yaml, which the pack gate makes compose default PACKTEST_VERSION to",
}

// Trees that hold build files nobody publishes: fetched dependencies, their
// vendored build output, and the archived task folders under .agent/tasks (one
// of which carries a devcontainer Dockerfile).
func skipDependabotDockerDir(rel string) bool {
	if rel == "portal/deps" {
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

// The file names Dependabot's docker ecosystem picks up in a listed directory.
func isDependabotDockerFile(name string) bool {
	switch name {
	case "compose.yml", "compose.yaml", "docker-compose.yml", "docker-compose.yaml":
		return true
	}
	return strings.HasPrefix(name, "Dockerfile") || strings.HasSuffix(name, ".Dockerfile")
}

// The `directories` (or `directory`) of the docker entry in .github/dependabot.yml.
func (a *App) dependabotDockerDirectories() ([]string, error) {
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
	var globs []string
	for _, update := range config.Updates {
		if update.Ecosystem != "docker" {
			continue
		}
		if update.Directory != "" {
			globs = append(globs, update.Directory)
		}
		globs = append(globs, update.Directories...)
	}
	if len(globs) == 0 {
		return nil, fmt.Errorf("%s declares no package-ecosystem: docker directories", relative)
	}
	for i, glob := range globs {
		// "/dev/runner/" and "/dev/runner" name the same directory; "/" is itself.
		if trimmed := strings.TrimSuffix(glob, "/"); trimmed != "" {
			globs[i] = trimmed
		}
	}
	return globs, nil
}

func (a *App) checkDependabotDockerCoverage() error {
	globs, err := a.dependabotDockerDirectories()
	if err != nil {
		return err
	}
	var uncovered []string
	found := 0
	claimed := map[string]bool{}
	walkErr := filepath.WalkDir(a.Root, func(full string, entry fs.DirEntry, err error) error {
		if err != nil {
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
		if !isDependabotDockerFile(entry.Name()) {
			return nil
		}
		found++
		if _, excluded := dependabotDockerExclusions[relative]; excluded {
			claimed[relative] = true
			return nil
		}
		// Dependabot directories are literal paths from the repository root, with
		// `*` matching one segment — the lane already relies on that for
		// "/packs/*/test".
		directory := "/" + path.Dir(relative)
		if directory == "/." {
			directory = "/"
		}
		for _, glob := range globs {
			matched, err := path.Match(glob, directory)
			if err != nil {
				return fmt.Errorf(".github/dependabot.yml: docker directory %q is not a valid pattern: %w", glob, err)
			}
			if matched {
				return nil
			}
		}
		uncovered = append(uncovered, fmt.Sprintf("%s: %s matches no docker directory", relative, directory))
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
			problems = append(problems, fmt.Sprintf("%s: excluded from the docker lane but no such build file exists", relative))
		}
	}
	if len(problems) > 0 {
		sort.Strings(problems)
		return fmt.Errorf("every Dockerfile/compose location must be in the .github/dependabot.yml docker lane "+
			"or in dependabotDockerExclusions with a reason:\n  %s", strings.Join(problems, "\n  "))
	}
	fmt.Fprintf(a.Out, "verified: all %d Dockerfile/compose locations are covered by the Dependabot docker lane or excluded with a reason\n", found)
	return nil
}
