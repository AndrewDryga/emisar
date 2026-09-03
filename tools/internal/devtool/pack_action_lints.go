package devtool

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"go.yaml.in/yaml/v3"
)

type packActionLintManifest struct {
	Actions  []string `yaml:"actions"`
	Requires struct {
		Binaries []string `yaml:"binaries"`
	} `yaml:"requires"`
}

type packActionLintInput struct {
	packDir          string
	actionPaths      []string
	requiredBinaries map[string]bool
}

func loadPackActionLintInput(packDir string) (packActionLintInput, error) {
	manifestPath := filepath.Join(packDir, "pack.yaml")
	data, err := os.ReadFile(manifestPath)
	if err != nil {
		return packActionLintInput{}, err
	}
	var manifest packActionLintManifest
	decoder := yaml.NewDecoder(bytes.NewReader(data))
	if err := decoder.Decode(&manifest); err != nil {
		return packActionLintInput{}, fmt.Errorf("parse %s: %w", manifestPath, err)
	}
	if err := decoder.Decode(&yaml.Node{}); err != io.EOF {
		if err == nil {
			err = fmt.Errorf("multiple YAML documents are not allowed")
		}
		return packActionLintInput{}, fmt.Errorf("parse %s: %w", manifestPath, err)
	}
	if len(manifest.Actions) == 0 {
		return packActionLintInput{}, fmt.Errorf("%s declares no actions", manifestPath)
	}

	root, err := filepath.Abs(packDir)
	if err != nil {
		return packActionLintInput{}, fmt.Errorf("resolve pack directory %s: %w", packDir, err)
	}
	resolvedRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return packActionLintInput{}, fmt.Errorf("resolve pack directory %s: %w", packDir, err)
	}
	paths := make([]string, 0, len(manifest.Actions))
	seen := make(map[string]string, len(manifest.Actions))
	for _, relative := range manifest.Actions {
		path, err := resolvePackLintActionPath(root, resolvedRoot, relative)
		if err != nil {
			return packActionLintInput{}, fmt.Errorf("%s action %q: %w", manifestPath, relative, err)
		}
		if previous, duplicate := seen[path]; duplicate {
			return packActionLintInput{}, fmt.Errorf(
				"%s declares the same action path twice: %q and %q", manifestPath, previous, relative,
			)
		}
		seen[path] = relative
		paths = append(paths, path)
	}
	sort.Strings(paths)

	required := make(map[string]bool, len(manifest.Requires.Binaries))
	for _, binary := range manifest.Requires.Binaries {
		required[binary] = true
	}
	return packActionLintInput{
		packDir:          root,
		actionPaths:      paths,
		requiredBinaries: required,
	}, nil
}

func resolvePackLintActionPath(root, resolvedRoot, relative string) (string, error) {
	if relative == "" {
		return "", fmt.Errorf("path is empty")
	}
	relative = filepath.FromSlash(relative)
	if filepath.IsAbs(relative) {
		return "", fmt.Errorf("path must be relative to the pack root")
	}
	path := filepath.Clean(filepath.Join(root, relative))
	if !pathWithinRoot(root, path) {
		return "", fmt.Errorf("path escapes the pack root")
	}
	info, err := os.Stat(path)
	if err != nil {
		return "", fmt.Errorf("path is not readable: %w", err)
	}
	if !info.Mode().IsRegular() {
		return "", fmt.Errorf("path is not a regular file")
	}
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return "", fmt.Errorf("resolve path: %w", err)
	}
	if !pathWithinRoot(resolvedRoot, resolved) {
		return "", fmt.Errorf("path escapes the pack root through a symlink")
	}
	return path, nil
}

func pathWithinRoot(root, path string) bool {
	relative, err := filepath.Rel(root, path)
	if err != nil {
		return false
	}
	return relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
}

func validatePackActionLints(ctx context.Context, packDir string) error {
	input, err := loadPackActionLintInput(packDir)
	if err != nil {
		return err
	}
	if err := validatePackHTTPFailures(input); err != nil {
		return err
	}
	if err := validatePackPipelineFailures(input); err != nil {
		return err
	}
	if err := validatePackJQFilters(input); err != nil {
		return err
	}
	if err := validatePackCurlURLSafety(input); err != nil {
		return err
	}
	if err := validatePackScriptSyntax(ctx, input); err != nil {
		return err
	}
	return validatePackInterpreterBinaries(input)
}
