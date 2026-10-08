package infraops

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

const diagnosticsBase = "debian:bookworm-20260918-slim@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251"

// qualifyAdminDiagnostics is intentionally outside the Docker-free infra gate.
// It builds once, extracts the final image, and executes those bytes on Linux
// at the production /run path, with no old sadc available to mask a broken build.
func (a *App) qualifyAdminDiagnostics(ctx context.Context, revision, image string) error {
	if !regexp.MustCompile(`^[a-f0-9]{40}$`).MatchString(revision) || !strings.HasPrefix(image, "emisar/admin-diagnostics:") {
		return usage("usage: ./run ops qualify-admin-diagnostics REVISION emisar/admin-diagnostics:TAG")
	}
	if err := a.require("docker"); err != nil {
		return err
	}
	if err := a.run(ctx, a.Root, nil, "docker", "build", "--platform", "linux/amd64",
		"--build-arg", "SOURCE_REVISION="+revision, "--file", "infra/runtime/admin-runner/diagnostics/Dockerfile", "--tag", image, "."); err != nil {
		return err
	}
	temp, err := os.MkdirTemp("", "emisar-admin-diagnostics-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(temp)
	cid, err := a.output(ctx, a.Root, nil, "docker", "create", "--network", "none", "--read-only", "--cap-drop=ALL", "--security-opt=no-new-privileges", image)
	if err != nil {
		return err
	}
	container := strings.TrimSpace(string(cid))
	defer func() {
		// Cleanup must still run if the qualification context was canceled.
		_ = a.run(context.Background(), a.Root, nil, "docker", "rm", container)
	}()
	if err := a.run(ctx, a.Root, nil, "docker", "cp", container+":/bundle", filepath.Join(temp, "bundle")); err != nil {
		return err
	}
	for _, path := range []string{"diagnostics/qualify.sh", "verify-diagnostics.sh"} {
		data, err := os.ReadFile(filepath.Join(a.Infra, "runtime/admin-runner", path))
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(temp, filepath.Base(path)), data, 0o644); err != nil {
			return err
		}
	}
	if err := a.run(ctx, a.Root, nil, "docker", "run", "--rm", "--platform", "linux/amd64", "--network", "none", "--read-only", "--cap-drop=ALL", "--security-opt=no-new-privileges",
		"--tmpfs", "/run:rw,exec,nosuid,nodev,size=256m", "--mount", "type=bind,src="+temp+",dst=/qualification,readonly", diagnosticsBase,
		"/bin/bash", "/qualification/qualify.sh", revision); err != nil {
		return fmt.Errorf("extracted Linux diagnostics qualification: %w", err)
	}
	fmt.Fprintf(a.Out, "qualified extracted Linux amd64 admin diagnostics: %s (%s)\n", image, revision)
	return nil
}
