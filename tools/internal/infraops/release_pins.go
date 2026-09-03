package infraops

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// The release shims call their trusted workflow at a pinned commit, and
// infra/github_oidc.tf grants the publisher's authority to that same commit.
// Forgetting terraform stops the release loudly. The other direction is silent
// and dangerous: edit a trusted workflow, forget the shim, and the shim still
// calls the OLD file at the old SHA — OIDC matches, the job is green, and the
// change ships nothing. So agreement between the three spellings is only half
// the check; the pinned commit must also still hold the workflow we have.
var (
	trustedWorkflowUse    = regexp.MustCompile(`(?m)^\s*uses:\s*\S+/(\.github/workflows/\S+-trusted\.yml)@([0-9a-f]{40})\s*$`)
	trustedTerraformSHA   = regexp.MustCompile(`(?m)^\s*trusted_job_workflow_sha\s*=\s*"([0-9a-f]{40})"\s*$`)
	trustedCompositeUse   = regexp.MustCompile(`(?m)^\s*-\s+uses:\s+\$/\.github/actions/verify-release-tag\s*$`)
	workspaceCompositeUse = regexp.MustCompile(`(?m)^\s*-\s+uses:\s+\./\.github/actions/verify-release-tag\s*$`)
)

var (
	trustedReleaseControlDirectories = []string{
		".github/actions/verify-release-tag",
		"tools/cmd/releaseenv",
		"tools/internal/releaseenv",
	}
	trustedReleaseControlFiles = []string{
		"tools/go.mod",
		"tools/go.sum",
	}
)

func (a *App) checkTrustedReleasePins(ctx context.Context) error {
	terraformPath := filepath.Join(a.Root, "infra", "github_oidc.tf")
	data, err := os.ReadFile(terraformPath)
	if err != nil {
		return err
	}
	match := trustedTerraformSHA.FindSubmatch(data)
	if match == nil {
		return fmt.Errorf("infra/github_oidc.tf does not assign trusted_job_workflow_sha")
	}
	trusted := string(match[1])

	shims, err := filepath.Glob(filepath.Join(a.Root, ".github", "workflows", "*-release.yml"))
	if err != nil {
		return err
	}
	pinned := map[string]string{}
	for _, shim := range shims {
		body, err := os.ReadFile(shim)
		if err != nil {
			return err
		}
		for _, use := range trustedWorkflowUse.FindAllSubmatch(body, -1) {
			workflow, sha := string(use[1]), string(use[2])
			name := filepath.Base(shim)
			if sha != trusted {
				return fmt.Errorf("%s calls %s@%s, but infra/github_oidc.tf trusts %s; the run would fail OIDC",
					name, workflow, sha, trusted)
			}
			pinned[workflow] = name
		}
	}
	if len(pinned) == 0 {
		return fmt.Errorf(".github/workflows holds no `uses: …-trusted.yml@<sha>` pin to verify")
	}

	for workflow, shim := range pinned {
		current, err := os.ReadFile(filepath.Join(a.Root, workflow))
		if err != nil {
			return fmt.Errorf("%s calls %s, which does not exist", shim, workflow)
		}
		if workspaceCompositeUse.Match(current) {
			return fmt.Errorf("%s loads verify-release-tag from the tag-selected workspace; use GitHub's $/ self-repository reference", workflow)
		}
		if uses := trustedCompositeUse.FindAll(current, -1); len(uses) != 1 {
			return fmt.Errorf("%s must call the pinned verify-release-tag composite exactly once through GitHub's $/ self-repository reference", workflow)
		}
		at, err := a.output(ctx, a.Root, nil, "git", "show", trusted+":"+workflow)
		if err != nil {
			return fmt.Errorf("reading %s at the pinned commit %s: %w", workflow, trusted, err)
		}
		if !bytes.Equal(current, at) {
			return fmt.Errorf("%s changed since %s, but %s and infra/github_oidc.tf still pin that commit — "+
				"the release would silently run the old workflow; commit the edit and re-pin all three to the new SHA",
				workflow, trusted[:12], shim)
		}
	}

	// The $/ self-repository reference resolves the composite at the reusable
	// workflow's pinned commit. That action runs only the narrow releaseenv
	// command, whose complete source and module inputs are tracked here too.
	// Including both pinned and current path sets catches added and deleted
	// files, not merely edits to a known filename.
	controls, err := a.trustedReleaseControlPaths(ctx, trusted)
	if err != nil {
		return err
	}
	for _, relative := range controls {
		current, err := os.ReadFile(filepath.Join(a.Root, filepath.FromSlash(relative)))
		if err != nil {
			return fmt.Errorf("trusted release control %s is missing from the working tree: %w", relative, err)
		}
		at, err := a.output(ctx, a.Root, nil, "git", "show", trusted+":"+relative)
		if err != nil {
			return fmt.Errorf("trusted release control %s does not exist at the pinned commit %s — commit it and re-pin the shims and infra/github_oidc.tf", relative, trusted[:12])
		}
		if !bytes.Equal(current, at) {
			return fmt.Errorf("trusted release control %s changed since %s, but the shims and infra/github_oidc.tf still pin that commit — "+
				"the release would silently run the old steps; re-pin all three to the new SHA",
				relative, trusted[:12])
		}
	}
	fmt.Fprintf(a.Out, "verified: %d trusted release workflow(s) pinned at %s in the shims and infra/github_oidc.tf\n",
		len(pinned), trusted[:12])
	return nil
}

func (a *App) trustedReleaseControlPaths(ctx context.Context, trusted string) ([]string, error) {
	pathspecs := append(append([]string{}, trustedReleaseControlDirectories...), trustedReleaseControlFiles...)

	currentArgs := []string{"ls-files", "--cached", "--others", "--exclude-standard", "--"}
	current, err := a.output(ctx, a.Root, nil, "git", append(currentArgs, pathspecs...)...)
	if err != nil {
		return nil, fmt.Errorf("listing current trusted release controls: %w", err)
	}
	pinnedArgs := []string{"ls-tree", "-r", "--name-only", trusted, "--"}
	pinned, err := a.output(ctx, a.Root, nil, "git", append(pinnedArgs, pathspecs...)...)
	if err != nil {
		return nil, fmt.Errorf("listing trusted release controls at %s: %w", trusted[:12], err)
	}

	set := make(map[string]struct{})
	for _, output := range [][]byte{current, pinned} {
		for _, path := range strings.Split(strings.TrimSpace(string(output)), "\n") {
			if path != "" {
				set[filepath.ToSlash(path)] = struct{}{}
			}
		}
	}
	paths := make([]string, 0, len(set))
	for path := range set {
		paths = append(paths, path)
	}
	sort.Strings(paths)
	return paths, nil
}
