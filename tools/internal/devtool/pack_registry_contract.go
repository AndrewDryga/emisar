package devtool

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
)

type packRegistryManifest struct {
	Objects []struct {
		Path      string `json:"path"`
		Immutable bool   `json:"immutable"`
	} `json:"objects"`
}

// checkPackRegistryPointerContract keeps packctl's mutable upload surface and
// Terraform's exact-object mutation grant in lockstep. A new pointer that is
// absent from the IAM contract would pass every local upload test and fail only
// after publication acquired production credentials.
func checkPackRegistryPointerContract(root, manifestPath string) error {
	manifestData, err := os.ReadFile(manifestPath)
	if err != nil {
		return fmt.Errorf("read pack registry manifest: %w", err)
	}
	var manifest packRegistryManifest
	if err := json.Unmarshal(manifestData, &manifest); err != nil {
		return fmt.Errorf("parse pack registry manifest: %w", err)
	}

	actual := make([]string, 0, len(manifest.Objects))
	for _, object := range manifest.Objects {
		if !object.Immutable {
			actual = append(actual, object.Path)
		}
	}
	actual, err = normalizedPointerPaths(actual)
	if err != nil {
		return fmt.Errorf("pack registry manifest: %w", err)
	}

	contractPath := filepath.Join(root, "infra", "pack_registry_mutable_pointers.json")
	contractData, err := os.ReadFile(contractPath)
	if err != nil {
		return fmt.Errorf("read pack registry IAM contract: %w", err)
	}
	var allowed []string
	if err := json.Unmarshal(contractData, &allowed); err != nil {
		return fmt.Errorf("parse pack registry IAM contract: %w", err)
	}
	allowed, err = normalizedPointerPaths(allowed)
	if err != nil {
		return fmt.Errorf("pack registry IAM contract: %w", err)
	}

	if !slices.Equal(actual, allowed) {
		return fmt.Errorf(
			"pack registry mutable objects and exact IAM grant differ: manifest has [%s], IAM permits [%s]",
			strings.Join(actual, ", "), strings.Join(allowed, ", "),
		)
	}
	return nil
}

func normalizedPointerPaths(paths []string) ([]string, error) {
	if len(paths) == 0 {
		return nil, fmt.Errorf("must name at least one mutable object")
	}
	normalized := append([]string(nil), paths...)
	sort.Strings(normalized)
	for i, path := range normalized {
		if path == "" {
			return nil, fmt.Errorf("contains an empty object path")
		}
		if i > 0 && normalized[i-1] == path {
			return nil, fmt.Errorf("contains duplicate object path %q", path)
		}
	}
	return normalized, nil
}
