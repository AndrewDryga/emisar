package packtest

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"go.yaml.in/yaml/v3"
)

// MirrorRow is one immutable source image and its digest-identical CI mirror.
type MirrorRow struct {
	Pack      string `json:"pack"`
	Version   string `json:"version"`
	Digest    string `json:"digest"`
	SourceRef string `json:"source_ref"`
	TargetTag string `json:"target_tag"`
	MirrorRef string `json:"mirror_ref"`
}

type mirrorConfig struct {
	Mirrors []mirrorSelection `yaml:"mirrors"`
}

type mirrorSelection struct {
	Pack   string `yaml:"pack"`
	Source string `yaml:"source"`
}

var (
	imageRepositoryPattern = regexp.MustCompile(`^[a-z0-9]+(?:[._/-][a-z0-9]+)*$`)
	tagCharacterPattern    = regexp.MustCompile(`[^a-z0-9_.-]+`)
)

// Mirrors expands the selected packs' committed compatibility versions into
// exact source and target refs. cases.yaml remains the owner of every version
// and digest; mirrors.yaml only selects expensive image repositories.
func Mirrors(packsDir, configPath, registry string) ([]MirrorRow, error) {
	registry = strings.TrimSuffix(strings.TrimSpace(registry), "/")
	if err := validateImageRepository(registry); err != nil {
		return nil, fmt.Errorf("mirror registry: %w", err)
	}
	data, err := os.ReadFile(configPath)
	if err != nil {
		return nil, err
	}
	var config mirrorConfig
	decoder := yaml.NewDecoder(bytes.NewReader(data))
	decoder.KnownFields(true)
	if err := decoder.Decode(&config); err != nil {
		return nil, fmt.Errorf("parse %s: %w", configPath, err)
	}
	if len(config.Mirrors) == 0 {
		return nil, fmt.Errorf("%s selects no mirrors", configPath)
	}

	names := make([]string, 0, len(config.Mirrors))
	selections := make(map[string]mirrorSelection, len(config.Mirrors))
	for index, selection := range config.Mirrors {
		if selection.Pack == "" || filepath.Base(selection.Pack) != selection.Pack || selection.Pack == "." {
			return nil, fmt.Errorf("mirrors[%d] has invalid pack %q", index, selection.Pack)
		}
		if err := validateImageRepository(selection.Source); err != nil {
			return nil, fmt.Errorf("mirrors[%d] source: %w", index, err)
		}
		if _, exists := selections[selection.Pack]; exists {
			return nil, fmt.Errorf("pack %s is selected more than once", selection.Pack)
		}
		selections[selection.Pack] = selection
		names = append(names, selection.Pack)
	}
	plans, err := Discover(packsDir, "", names...)
	if err != nil {
		return nil, err
	}

	rows := make([]MirrorRow, 0, len(plans)*2)
	tags := make(map[string]bool)
	for _, plan := range plans {
		selection := selections[plan.Name]
		composePath := filepath.Join(filepath.Dir(plan.Path), "compose.yaml")
		compose, err := os.ReadFile(composePath)
		if err != nil {
			return nil, fmt.Errorf("%s: read compose.yaml: %w", plan.Name, err)
		}
		imageDefault := "${PACKTEST_IMAGE:-" + selection.Source + ":"
		if !bytes.Contains(compose, []byte(imageDefault)) {
			return nil, fmt.Errorf("%s: compose.yaml must opt in through %s", plan.Name, imageDefault)
		}
		for _, version := range plan.Versions {
			tag := mirrorTag(plan.Name, version.Version)
			if tags[tag] {
				return nil, fmt.Errorf("mirror tag %s is not unique", tag)
			}
			tags[tag] = true
			targetTag := registry + ":" + tag
			rows = append(rows, MirrorRow{
				Pack:      plan.Name,
				Version:   version.Version,
				Digest:    version.Digest,
				SourceRef: selection.Source + ":" + version.Version + version.Digest,
				TargetTag: targetTag,
				MirrorRef: targetTag + version.Digest,
			})
		}
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].Pack == rows[j].Pack {
			return rows[i].Version < rows[j].Version
		}
		return rows[i].Pack < rows[j].Pack
	})
	return rows, nil
}

// ResolveMirror returns a mirror only for an exact pack, version, and digest.
// A locally supplied version or a changed digest always stays on its source.
func ResolveMirror(rows []MirrorRow, pack, version, digest string) (MirrorRow, bool) {
	for _, row := range rows {
		if row.Pack == pack && row.Version == version && row.Digest == digest {
			return row, true
		}
	}
	return MirrorRow{}, false
}

func validateImageRepository(repository string) error {
	if repository == "" || repository != strings.ToLower(repository) ||
		strings.ContainsAny(repository, "@:\t\r\n ") || !imageRepositoryPattern.MatchString(repository) {
		return fmt.Errorf("%q must be a lowercase image repository without a tag or digest", repository)
	}
	return nil
}

func mirrorTag(pack, version string) string {
	tag := strings.ToLower(pack + "-" + version)
	tag = strings.Trim(tagCharacterPattern.ReplaceAllString(tag, "-"), ".-")
	if len(tag) > 128 {
		tag = tag[:128]
	}
	return tag
}
