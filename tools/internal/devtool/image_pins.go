package devtool

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// The repository-owned stacks that run Postgres and Keycloak: the e2e stack
// (the reference), the workspace stack behind ./run up and the Portal gates,
// the publication-review stack that decides whether a PR opens, and CI's
// service containers. docker-compose.yml explains why each image carries a
// digest; the others had been left on bare tags, so a republished tag could
// change the database that green-lit a release while the reference stayed
// pinned — and CI spelled the same digest under a coarser tag, so a grep for
// the version missed it.
var sharedServiceImageFiles = []string{
	"docker-compose.yml",
	"dev/compose.yml",
	"dev/review-compose.yml",
	".github/workflows/ci.yml",
}

var sharedServiceImageRepos = []string{"postgres", "quay.io/keycloak/keycloak"}

// A Compose or workflow `image:` line, allowing the YAML anchor CI uses.
var serviceImageLine = regexp.MustCompile(`(?m)^[ \t]*image:[ \t]*(?:&\S+[ \t]+)?(\S+)`)

func (a *App) checkSharedServiceImagePins() error {
	type declaration struct {
		file  string
		line  int
		image string
	}
	found := map[string][]declaration{}
	for _, file := range sharedServiceImageFiles {
		data, err := os.ReadFile(filepath.Join(a.Root, filepath.FromSlash(file)))
		if err != nil {
			return err
		}
		for _, match := range serviceImageLine.FindAllSubmatchIndex(data, -1) {
			image := string(data[match[2]:match[3]])
			for _, repo := range sharedServiceImageRepos {
				if strings.HasPrefix(image, repo+":") {
					line := 1 + strings.Count(string(data[:match[0]]), "\n")
					found[repo] = append(found[repo], declaration{file, line, image})
				}
			}
		}
	}
	var problems []string
	for _, repo := range sharedServiceImageRepos {
		declarations := found[repo]
		if len(declarations) == 0 {
			return fmt.Errorf("no %s image is declared in %s", repo, strings.Join(sharedServiceImageFiles, ", "))
		}
		reference := declarations[0]
		if reference.file != sharedServiceImageFiles[0] {
			return fmt.Errorf("%s does not declare %s, so nothing is the reference pin", sharedServiceImageFiles[0], repo)
		}
		if !strings.Contains(reference.image, "@sha256:") {
			problems = append(problems, fmt.Sprintf("%s:%d: %s is not digest-pinned", reference.file, reference.line, reference.image))
		}
		for _, declaration := range declarations[1:] {
			if declaration.image != reference.image {
				problems = append(problems, fmt.Sprintf("%s:%d: %s differs from %s:%d: %s",
					declaration.file, declaration.line, declaration.image, reference.file, reference.line, reference.image))
			}
		}
	}
	if len(problems) > 0 {
		return fmt.Errorf("shared service images must carry one tag@digest everywhere:\n  %s", strings.Join(problems, "\n  "))
	}
	fmt.Fprintln(a.Out, "verified: every repository stack pins the same Postgres and Keycloak tag@digest")
	return nil
}
