package infraops

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Build and copy the same bundle production installs, then execute its helpers
// as native processes. No privileged container, socket mount, or host namespace
// is needed to test relocation and the private ELF/Python dependency closure.
func (a *App) validateAdminDiagnostics(ctx context.Context) error {
	source := filepath.Join(a.Infra, "runtime/admin-runner/diagnostics")
	image := "emisar/admin-diagnostics:check"
	if err := a.run(ctx, a.Root, nil, "docker", "build", "--tag", image, source); err != nil {
		return err
	}
	containerBytes, err := a.output(ctx, a.Root, nil, "docker", "create", image)
	if err != nil {
		return err
	}
	container := strings.TrimSpace(string(containerBytes))
	defer func() { _ = a.run(ctx, a.Root, nil, "docker", "rm", container) }()
	temp, err := os.MkdirTemp("", "emisar-admin-diagnostics-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(temp)
	if err := a.run(ctx, a.Root, nil, "docker", "cp", container+":/bundle/.", temp); err != nil {
		return err
	}
	data, err := os.ReadFile(filepath.Join(temp, "commands.txt"))
	if err != nil {
		return err
	}
	for _, command := range strings.Fields(string(data)) {
		if command == "ntpq" {
			command = "python3"
		}
		if err := a.run(ctx, a.Root, nil, filepath.Join(temp, "lib/loader"), "--library-path", filepath.Join(temp, "lib"), "--list", filepath.Join(temp, "libexec", command)); err != nil {
			return fmt.Errorf("admin diagnostics %s library closure: %w", command, err)
		}
	}
	for _, argv := range [][]string{
		{"iostat", "-V"}, {"sadc", "-V"}, {"sar", "-u", "1", "1"},
		{"free", "-b"}, {"vmstat", "1", "2"}, {"ntpq", "--version"},
		{"chronyc", "-v"}, {"jq", "--version"},
	} {
		if err := a.run(ctx, a.Root, nil, filepath.Join(temp, "bin", argv[0]), argv[1:]...); err != nil {
			return fmt.Errorf("native admin diagnostics %s smoke: %w", argv[0], err)
		}
	}
	return a.run(ctx, a.Root, nil, filepath.Join(temp, "cli-plugins/docker-compose"), "version")
}
