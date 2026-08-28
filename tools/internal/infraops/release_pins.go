package infraops

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
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
	trustedWorkflowUse  = regexp.MustCompile(`(?m)^\s*uses:\s*\S+/(\.github/workflows/\S+-trusted\.yml)@([0-9a-f]{40})\s*$`)
	trustedTerraformSHA = regexp.MustCompile(`(?m)^\s*trusted_job_workflow_sha\s*=\s*"([0-9a-f]{40})"\s*$`)
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
		at, err := a.output(ctx, a.Root, nil, "git", "show", trusted+":"+workflow)
		if err != nil {
			return fmt.Errorf("reading %s at the pinned commit %s: %w", workflow, trusted, err)
		}
		if !strings.EqualFold(string(current), string(at)) {
			return fmt.Errorf("%s changed since %s, but %s and infra/github_oidc.tf still pin that commit — "+
				"the release would silently run the old workflow; commit the edit and re-pin all three to the new SHA",
				workflow, trusted[:12], shim)
		}
	}

	// Repo-local composite actions execute at the same pinned commit (a
	// `uses: ./.github/actions/...` inside a reusable workflow resolves in the
	// CALLED workflow's tree), so an edited composite with a stale pin is the
	// same silent failure one directory over: the release runs the OLD steps,
	// green, and the change ships nothing.
	actions, err := filepath.Glob(filepath.Join(a.Root, ".github", "actions", "*", "*.yml"))
	if err != nil {
		return err
	}
	for _, path := range actions {
		relative, err := filepath.Rel(a.Root, path)
		if err != nil {
			return err
		}
		relative = filepath.ToSlash(relative)
		current, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		at, err := a.output(ctx, a.Root, nil, "git", "show", trusted+":"+relative)
		if err != nil {
			return fmt.Errorf("%s does not exist at the pinned commit %s — commit it and re-pin the shims and infra/github_oidc.tf", relative, trusted[:12])
		}
		if !strings.EqualFold(string(current), string(at)) {
			return fmt.Errorf("%s changed since %s, but the shims and infra/github_oidc.tf still pin that commit — "+
				"the release would silently run the old steps; re-pin all three to the new SHA",
				relative, trusted[:12])
		}
	}
	if err := a.checkInstallerSignerWorkflows(); err != nil {
		return err
	}
	fmt.Fprintf(a.Out, "verified: %d trusted release workflow(s) pinned at %s in the shims and infra/github_oidc.tf\n",
		len(pinned), trusted[:12])
	return nil
}

// The attesting job runs inside the -trusted reusable workflow, so the Sigstore
// certificate SAN carries that ref — not the thin caller. Every consumer that
// verifies release provenance (the two installers, the PowerShell installer,
// and the self-updater) must therefore name a *-release-trusted.yml signer, or
// the first release after a workflow split refuses to install on exactly the
// security-conscious hosts that check provenance. This is a plain string check,
// independent of the pin rotation above.
func (a *App) checkInstallerSignerWorkflows() error {
	// path -> regex capturing the workflow ref the file names as its signer.
	signerRefs := map[string]*regexp.Regexp{
		"install.sh":      regexp.MustCompile(`AndrewDryga/emisar/\.github/workflows/(\S+?\.yml)`),
		"install-mcp.sh":  regexp.MustCompile(`AndrewDryga/emisar/\.github/workflows/(\S+?\.yml)`),
		"install-mcp.ps1": regexp.MustCompile(`AndrewDryga/emisar/\.github/workflows/(\S+?\.yml)`),
		"runner/internal/selfupdate/selfupdate.go": regexp.MustCompile(`AndrewDryga/emisar/\.github/workflows/(\S+?\.yml)`),
	}
	for rel, pattern := range signerRefs {
		body, err := os.ReadFile(filepath.Join(a.Root, filepath.FromSlash(rel)))
		if err != nil {
			return err
		}
		matches := pattern.FindAllSubmatch(body, -1)
		if len(matches) == 0 {
			return fmt.Errorf("%s names no release signer workflow — provenance verification cannot resolve", rel)
		}
		for _, m := range matches {
			ref := string(m[1])
			if !strings.HasSuffix(ref, "-trusted.yml") {
				return fmt.Errorf("%s verifies against %s, but the attesting job runs inside the -trusted reusable workflow; "+
					"point it at the *-release-trusted.yml signer or the next signed release is refused", rel, ref)
			}
		}
	}
	return nil
}
