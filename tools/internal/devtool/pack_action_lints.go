package devtool

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"

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
	// The runner validates manifest paths before this tooling runs; this loader
	// only selects the files and binaries the text lints need.
	manifestPath := filepath.Join(packDir, "pack.yaml")
	data, err := os.ReadFile(manifestPath)
	if err != nil {
		return packActionLintInput{}, err
	}
	var manifest packActionLintManifest
	if err := yaml.Unmarshal(data, &manifest); err != nil {
		return packActionLintInput{}, fmt.Errorf("parse %s: %w", manifestPath, err)
	}
	paths := make([]string, 0, len(manifest.Actions))
	for _, relative := range manifest.Actions {
		paths = append(paths, filepath.Join(packDir, filepath.FromSlash(relative)))
	}
	sort.Strings(paths)

	required := make(map[string]bool, len(manifest.Requires.Binaries))
	for _, binary := range manifest.Requires.Binaries {
		required[binary] = true
	}
	return packActionLintInput{
		packDir:          packDir,
		actionPaths:      paths,
		requiredBinaries: required,
	}, nil
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
