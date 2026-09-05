// Package hostaccess proves the operator-run host access recipes published by
// action packs against disposable systemd hosts.
package hostaccess

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"

	"go.yaml.in/yaml/v3"
)

const commandTimeout = 2 * time.Minute

type recipe struct {
	Name     string   `yaml:"name"`
	Commands []string `yaml:"commands"`
	Verify   []string `yaml:"verify"`
}

type accessGroup struct {
	Actions []string `yaml:"actions"`
	Recipes []recipe `yaml:"recipes"`
}

type manifest struct {
	ID    string `yaml:"id"`
	Setup struct {
		HostAccess []accessGroup `yaml:"host_access"`
	} `yaml:"setup"`
}

type proofFile struct {
	Recipes []proof `yaml:"recipes"`
}

type proof struct {
	Access   int      `yaml:"access"`
	Recipe   int      `yaml:"recipe"`
	Fixture  string   `yaml:"fixture"`
	Action   string   `yaml:"action"`
	Prepare  []string `yaml:"prepare"`
	Recreate []string `yaml:"recreate,omitempty"`
	Probe    string   `yaml:"probe"`
}

// Row is one exact manifest recipe plus its pack-owned executable proof.
type Row struct {
	Pack      string
	Access    int
	Recipe    int
	Name      string
	Fixture   string
	Action    string
	Commands  []string
	Verify    []string
	Prepare   []string
	Recreate  []string
	Probe     string
	ProofPath string
}

func (row Row) ID() string {
	return fmt.Sprintf("%s:%d.%d", row.Pack, row.Access, row.Recipe)
}

// Discover loads every structured host-access recipe and requires one exact,
// pack-owned proof for it. A selected pack without host access is rejected so
// a misspelled command cannot silently test nothing.
func Discover(packsDir string, names ...string) ([]Row, error) {
	wanted := make(map[string]bool, len(names))
	for _, name := range names {
		if name == "" || filepath.Base(name) != name || name == "." {
			return nil, fmt.Errorf("invalid pack name %q", name)
		}
		wanted[name] = true
	}

	paths, err := filepath.Glob(filepath.Join(packsDir, "*", "pack.yaml"))
	if err != nil {
		return nil, err
	}
	sort.Strings(paths)
	var rows []Row
	found := make(map[string]bool, len(wanted))
	for _, path := range paths {
		packName := filepath.Base(filepath.Dir(path))
		if len(wanted) > 0 && !wanted[packName] {
			continue
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		var pack manifest
		if err := yaml.Unmarshal(data, &pack); err != nil {
			return nil, fmt.Errorf("parse %s: %w", path, err)
		}
		if len(pack.Setup.HostAccess) == 0 {
			continue
		}
		found[packName] = true
		proofPath := filepath.Join(filepath.Dir(path), "test", "host_access.yaml")
		proofs, err := loadProofs(proofPath)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", packName, err)
		}
		packRows, err := matchProofs(packName, proofPath, pack.Setup.HostAccess, proofs)
		if err != nil {
			return nil, err
		}
		rows = append(rows, packRows...)
	}
	if len(wanted) > 0 {
		var missing []string
		for name := range wanted {
			if !found[name] {
				missing = append(missing, name)
			}
		}
		if len(missing) > 0 {
			sort.Strings(missing)
			return nil, fmt.Errorf("packs have no host-access recipes: %s", strings.Join(missing, ", "))
		}
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("no host-access recipes matched the selection")
	}
	return rows, nil
}

func loadProofs(path string) ([]proof, error) {
	file, err := os.Open(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("missing executable proof %s", path)
		}
		return nil, err
	}
	defer file.Close()
	decoder := yaml.NewDecoder(file)
	decoder.KnownFields(true)
	var plan proofFile
	if err := decoder.Decode(&plan); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	return plan.Recipes, nil
}

func matchProofs(pack, path string, groups []accessGroup, proofs []proof) ([]Row, error) {
	want := make(map[string]Row)
	for groupIndex, group := range groups {
		for recipeIndex, value := range group.Recipes {
			key := selector(groupIndex, recipeIndex)
			want[key] = Row{
				Pack: pack, Access: groupIndex, Recipe: recipeIndex, Name: value.Name,
				Commands: value.Commands, Verify: value.Verify, ProofPath: path,
			}
		}
	}
	seen := make(map[string]bool, len(proofs))
	for index, value := range proofs {
		location := fmt.Sprintf("%s recipes[%d]", path, index)
		key := selector(value.Access, value.Recipe)
		row, exists := want[key]
		if !exists {
			return nil, fmt.Errorf("%s selects missing setup.host_access recipe %s", location, key)
		}
		if seen[key] {
			return nil, fmt.Errorf("%s duplicates setup.host_access recipe %s", location, key)
		}
		seen[key] = true
		if value.Fixture != "debian" && value.Fixture != "fedora" {
			return nil, fmt.Errorf("%s fixture %q must be debian or fedora", location, value.Fixture)
		}
		if !slices.Contains(groups[value.Access].Actions, value.Action) {
			return nil, fmt.Errorf("%s action %q is not mapped by setup.host_access[%d]", location, value.Action, value.Access)
		}
		if strings.TrimSpace(value.Probe) == "" {
			return nil, fmt.Errorf("%s probe must not be empty", location)
		}
		if len(value.Prepare) == 0 {
			return nil, fmt.Errorf("%s prepare must establish a denied baseline", location)
		}
		row.Fixture = value.Fixture
		row.Action = value.Action
		row.Prepare = value.Prepare
		row.Recreate = value.Recreate
		row.Probe = value.Probe
		want[key] = row
	}
	var missing []string
	for key := range want {
		if !seen[key] {
			missing = append(missing, key)
		}
	}
	if len(missing) > 0 {
		sort.Strings(missing)
		return nil, fmt.Errorf("%s does not prove setup.host_access recipes: %s", pack, strings.Join(missing, ", "))
	}
	keys := make([]string, 0, len(want))
	for key := range want {
		keys = append(keys, key)
	}
	sort.Slice(keys, func(i, j int) bool {
		left := want[keys[i]]
		right := want[keys[j]]
		return left.Access < right.Access || left.Access == right.Access && left.Recipe < right.Recipe
	})
	rows := make([]Row, 0, len(keys))
	for _, key := range keys {
		rows = append(rows, want[key])
	}
	return rows, nil
}

func selector(access, recipe int) string {
	return strconv.Itoa(access) + "." + strconv.Itoa(recipe)
}

// Run executes the selected rows. The exact manifest commands are never copied
// into proof files, so the executable evidence cannot silently drift from what
// an operator sees.
func Run(ctx context.Context, root string, rows []Row, out io.Writer) error {
	images := make(map[string]string)
	for _, row := range rows {
		if _, exists := images[row.Fixture]; exists {
			continue
		}
		image, err := buildImage(ctx, root, row.Fixture, out)
		if err != nil {
			return err
		}
		images[row.Fixture] = image
	}

	var failures []string
	for _, row := range rows {
		started := time.Now()
		if err := runRow(ctx, images[row.Fixture], row); err != nil {
			fmt.Fprintf(out, "FAIL %s %s (%s): %v\n", row.ID(), row.Name, row.Action, err)
			failures = append(failures, row.ID())
			continue
		}
		fmt.Fprintf(out, "PASS %s %s (%s) duration=%s\n", row.ID(), row.Name, row.Action, time.Since(started).Round(time.Millisecond))
	}
	if len(failures) > 0 {
		return fmt.Errorf("host-access proofs failed: %s", strings.Join(failures, ", "))
	}
	fmt.Fprintf(out, "\nHost-access recipes proved: %d\n", len(rows))
	return nil
}

func buildImage(ctx context.Context, root, fixture string, out io.Writer) (string, error) {
	dir := filepath.Join(root, "dev", "test-host-access")
	contents, err := os.ReadFile(filepath.Join(dir, "Dockerfile."+fixture))
	if err != nil {
		return "", err
	}
	helper, err := os.ReadFile(filepath.Join(dir, "emisar-service-probe"))
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256(append(contents, helper...))
	image := fmt.Sprintf("emisar-host-access-%s:%x", fixture, digest[:6])
	if err := runCommand(ctx, io.Discard, root, "docker", "image", "inspect", image); err == nil {
		return image, nil
	}
	if err := runCommand(ctx, out, root, "docker", "build", "--file", filepath.Join(dir, "Dockerfile."+fixture), "--tag", image, dir); err != nil {
		return "", fmt.Errorf("build %s host-access fixture: %w", fixture, err)
	}
	return image, nil
}

func runRow(ctx context.Context, image string, row Row) (err error) {
	name := containerName(row)
	defer func() {
		cleanupCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		_ = runCommand(cleanupCtx, io.Discard, "", "docker", "rm", "--force", name)
	}()
	if err := runCommand(ctx, io.Discard, "", "docker", "run", "--detach", "--name", name,
		"--privileged", "--cgroupns=host", "--env", "container=docker",
		"--volume", "/sys/fs/cgroup:/sys/fs/cgroup:rw", image); err != nil {
		return err
	}
	if err := waitForSystemd(ctx, name); err != nil {
		return err
	}
	for _, command := range row.Prepare {
		if err := execShell(ctx, name, command); err != nil {
			return fmt.Errorf("prepare: %w", err)
		}
	}
	if err := execProbe(ctx, name, row.Probe); err == nil {
		return fmt.Errorf("denied baseline unexpectedly passed")
	}
	for _, command := range row.Commands {
		if err := execShell(ctx, name, command); err != nil {
			return fmt.Errorf("recipe command %q: %w", command, err)
		}
	}
	if err := verify(ctx, name, row.Verify); err != nil {
		return fmt.Errorf("initial verify: %w", err)
	}
	for _, command := range row.Recreate {
		if err := execShell(ctx, name, command); err != nil {
			return fmt.Errorf("recreate protected resource: %w", err)
		}
	}
	if err := execShell(ctx, name, "systemctl restart emisar.service"); err != nil {
		return fmt.Errorf("restart emisar service: %w", err)
	}
	if err := verify(ctx, name, row.Verify); err != nil {
		return fmt.Errorf("post-restart verify: %w", err)
	}
	if err := execProbe(ctx, name, row.Probe); err != nil {
		return fmt.Errorf("mapped action %s protected-resource probe: %w", row.Action, err)
	}
	return nil
}

func containerName(row Row) string {
	name := strings.Map(func(value rune) rune {
		if value >= 'a' && value <= 'z' || value >= '0' && value <= '9' || value == '-' {
			return value
		}
		return '-'
	}, strings.ToLower(row.Pack))
	return fmt.Sprintf("emisar-host-access-%s-%d-%d-%d", name, row.Access, row.Recipe, os.Getpid())
}

func waitForSystemd(ctx context.Context, container string) error {
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		if err := runCommand(ctx, io.Discard, "", "docker", "exec", container,
			"systemctl", "is-active", "--quiet", "emisar.service"); err == nil {
			return nil
		}
		time.Sleep(500 * time.Millisecond)
	}
	return fmt.Errorf("systemd fixture did not start emisar.service")
}

func verify(ctx context.Context, container string, commands []string) error {
	for _, command := range commands {
		if err := execShell(ctx, container, command); err != nil {
			return fmt.Errorf("%q: %w", command, err)
		}
	}
	return nil
}

func execShell(ctx context.Context, container, command string) error {
	return runCommand(ctx, io.Discard, "", "docker", "exec", container,
		"/bin/bash", "-euxo", "pipefail", "-c", command)
}

func execProbe(ctx context.Context, container, command string) error {
	return runCommand(ctx, io.Discard, "", "docker", "exec", container,
		"/usr/local/bin/emisar-service-probe", command)
}

func runCommand(ctx context.Context, output io.Writer, dir, name string, args ...string) error {
	commandCtx, cancel := context.WithTimeout(ctx, commandTimeout)
	defer cancel()
	command := exec.CommandContext(commandCtx, name, args...)
	command.Dir = dir
	var combined strings.Builder
	command.Stdout = io.MultiWriter(output, &combined)
	command.Stderr = io.MultiWriter(output, &combined)
	if err := command.Run(); err != nil {
		if errors.Is(commandCtx.Err(), context.DeadlineExceeded) {
			return fmt.Errorf("timed out after %s: %s %s", commandTimeout, name, strings.Join(args, " "))
		}
		message := strings.TrimSpace(combined.String())
		if message != "" {
			return fmt.Errorf("%s %s: %w (%s)", name, strings.Join(args, " "), err, message)
		}
		return fmt.Errorf("%s %s: %w", name, strings.Join(args, " "), err)
	}
	return nil
}
