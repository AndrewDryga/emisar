package devtool

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"go.yaml.in/yaml/v3"
)

type packVersionManifest struct {
	Version       string `yaml:"version"`
	RetiredBelow  string `yaml:"retired_below"`
	SchemaVersion int    `yaml:"schema_version"`
}

// validatePackVersions rejects a version this repository's own packs cannot
// publish.
//
// Four things judge a pack version and they do NOT agree, on purpose for three
// of them:
//
//   - packspec's loader accepts almost anything (alphanumeric start, then
//     `.`/`-`/`+`) because a third-party or hand-built pack may label itself
//     however it likes, and the runner still has to load it.
//   - the portal's runner_action column matches that, because it stores what a
//     runner advertised.
//   - the MCP projection accepts dot-numeric plus SemVer's prerelease and build
//     suffixes, deliberately widened after versions "vanished from list_packs
//     with no issue code".
//   - `packctl catalog build` requires STRICT dot-numeric, because the portal's
//     retirement compare parses each component as an integer and must fail
//     closed on junk.
//
// The gap is between authoring and publishing. A pack in packs/ numbered
// `1.0.0-rc1` loads, advertises, persists, produces a valid pack_ref and can be
// signed — and then can never be published, because the fourth check refuses
// it. The failure arrives at release time, long after the version was chosen.
//
// packs/ is first-party input destined for our own registry, so it gets an
// authoring-time lint instead (shared-solve-the-owned-problem). Third-party
// packs keep the permissive loader; this only speaks for the tree we publish.
func validatePackVersions(packDir string) error {
	data, err := os.ReadFile(filepath.Join(packDir, "pack.yaml"))
	if err != nil {
		return err
	}
	var manifest packVersionManifest
	if err := yaml.Unmarshal(data, &manifest); err != nil {
		return fmt.Errorf("%s/pack.yaml: %w", filepath.Base(packDir), err)
	}
	name := filepath.Base(packDir)

	if err := publishableVersion(manifest.Version); err != nil {
		return fmt.Errorf("%s/pack.yaml: version: %w", name, err)
	}
	// A retirement floor is compared against published versions with the same
	// parser, so it has to be spellable the same way.
	if manifest.RetiredBelow != "" {
		if err := publishableVersion(manifest.RetiredBelow); err != nil {
			return fmt.Errorf("%s/pack.yaml: retired_below: %w", name, err)
		}
	}
	return nil
}

// publishableVersion mirrors catalog.parseVersion, the check that runs at
// publish time. Kept as a plain reimplementation rather than an import because
// that one lives in the runner module's internal/ tree, which another module
// cannot reach — so the test below pins the two against the same cases.
func publishableVersion(v string) error {
	if v == "" {
		return fmt.Errorf("is required")
	}
	for _, part := range strings.Split(v, ".") {
		n, err := strconv.Atoi(part)
		if err != nil || n < 0 {
			return fmt.Errorf(
				"%q is not publishable: every component must be a non-negative integer, "+
					"so a SemVer prerelease or build suffix (1.0.0-rc1, 2.0.0+build) validates "+
					"and installs but can never reach the registry", v)
		}
	}
	return nil
}
