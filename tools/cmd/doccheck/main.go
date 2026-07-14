// Command doccheck verifies the repository documentation contract: relative
// Markdown links resolve to version-controlled files, and tracked source does
// not depend on private local agent-history paths.
package main

import (
	"bytes"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/andrewdryga/emisar/tools/internal/repo"
)

var markdownLink = regexp.MustCompile(`!?\[[^\]]*\]\(([^)\n]+)\)`)

type finding struct {
	file    string
	message string
}

func versionedCandidates(root string) ([]string, error) {
	cmd := exec.Command("git", "ls-files", "--cached", "--others", "--exclude-standard", "-z")
	cmd.Dir = root
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("listing version-controlled files: %w", err)
	}

	parts := bytes.Split(out, []byte{0})
	files := make([]string, 0, len(parts))
	for _, part := range parts {
		if len(part) > 0 {
			files = append(files, filepath.ToSlash(string(part)))
		}
	}
	sort.Strings(files)
	return files, nil
}

func linkDestination(raw string) string {
	raw = strings.TrimSpace(raw)
	if strings.HasPrefix(raw, "<") {
		if end := strings.Index(raw, ">"); end >= 0 {
			raw = raw[1:end]
		}
	} else if fields := strings.Fields(raw); len(fields) > 0 {
		raw = fields[0]
	}

	if raw == "" || strings.HasPrefix(raw, "#") || strings.HasPrefix(raw, "/") ||
		strings.HasPrefix(raw, "//") {
		return ""
	}
	if parsed, err := url.Parse(raw); err == nil && parsed.Scheme != "" {
		return ""
	}

	raw, _, _ = strings.Cut(raw, "#")
	raw, _, _ = strings.Cut(raw, "?")
	if decoded, err := url.PathUnescape(raw); err == nil {
		raw = decoded
	}
	return raw
}

func hasTrackedTarget(target string, tracked map[string]struct{}) bool {
	if _, ok := tracked[target]; ok {
		return true
	}
	prefix := strings.TrimSuffix(target, "/") + "/"
	for file := range tracked {
		if strings.HasPrefix(file, prefix) {
			return true
		}
	}
	return false
}

func checkMarkdownLinks(file string, data []byte, tracked map[string]struct{}) []finding {
	var findings []finding
	for _, match := range markdownLink.FindAllSubmatch(data, -1) {
		destination := linkDestination(string(match[1]))
		if destination == "" {
			continue
		}

		target := path.Clean(path.Join(path.Dir(file), filepath.ToSlash(destination)))
		if target == ".." || strings.HasPrefix(target, "../") {
			findings = append(findings, finding{file, fmt.Sprintf("relative link escapes repository: %s", destination)})
			continue
		}
		if !hasTrackedTarget(target, tracked) {
			findings = append(findings, finding{file, fmt.Sprintf("relative link target is not version-controlled: %s", destination)})
		}
	}
	return findings
}

func containsReference(data []byte, needle string) bool {
	start := 0
	for {
		index := bytes.Index(data[start:], []byte(needle))
		if index < 0 {
			return false
		}
		end := start + index + len(needle)
		if end == len(data) || !isPathNameByte(data[end]) {
			return true
		}
		start += index + 1
	}
}

func isPathNameByte(value byte) bool {
	return value >= 'a' && value <= 'z' || value >= 'A' && value <= 'Z' ||
		value >= '0' && value <= '9' || value == '_' || value == '-'
}

func forbiddenVersionedPath(file string) bool {
	parts := strings.Split(file, "/")
	for index, part := range parts {
		if part != ".agent" {
			continue
		}
		subpath := strings.Join(parts[index+1:], "/")
		if subpath == "project.yaml" || strings.HasPrefix(subpath, "rules/") ||
			strings.HasPrefix(subpath, "scripts/") {
			return false
		}
		return true
	}
	return false
}

func privateAgentReferences(data []byte) []string {
	var hits []string
	for _, dir := range []string{"features", "review", "reviews", "design", "specs", "screenshots"} {
		needle := ".agent/" + dir
		if containsReference(data, needle) {
			hits = append(hits, needle)
		}
	}
	return hits
}

func checkRepository(root string) ([]finding, int, error) {
	files, err := versionedCandidates(root)
	if err != nil {
		return nil, 0, err
	}

	tracked := make(map[string]struct{}, len(files))
	for _, file := range files {
		if _, err := os.Lstat(filepath.Join(root, filepath.FromSlash(file))); err == nil {
			tracked[file] = struct{}{}
		}
	}

	var findings []finding
	markdownFiles := 0
	for _, file := range files {
		if forbiddenVersionedPath(file) {
			findings = append(findings, finding{file, "private or local artifact path must not be version-controlled"})
			continue
		}
		fullPath := filepath.Join(root, filepath.FromSlash(file))
		info, err := os.Stat(fullPath)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return nil, markdownFiles, fmt.Errorf("stating %s: %w", file, err)
		}
		if info.IsDir() {
			continue
		}
		data, err := os.ReadFile(fullPath)
		if err != nil {
			return nil, markdownFiles, fmt.Errorf("reading %s: %w", file, err)
		}
		if bytes.IndexByte(data, 0) >= 0 {
			continue
		}

		for _, private := range privateAgentReferences(data) {
			findings = append(findings, finding{file, "references private local artifact " + private})
		}
		if strings.HasSuffix(strings.ToLower(file), ".md") {
			markdownFiles++
			findings = append(findings, checkMarkdownLinks(file, data, tracked)...)
		}
	}

	sort.Slice(findings, func(i, j int) bool {
		if findings[i].file == findings[j].file {
			return findings[i].message < findings[j].message
		}
		return findings[i].file < findings[j].file
	})
	return findings, markdownFiles, nil
}

func main() {
	root, err := repo.Root()
	if err != nil {
		fmt.Fprintln(os.Stderr, "doccheck:", err)
		os.Exit(2)
	}
	findings, markdownFiles, err := checkRepository(root)
	if err != nil {
		fmt.Fprintln(os.Stderr, "doccheck:", err)
		os.Exit(2)
	}
	if len(findings) > 0 {
		for _, finding := range findings {
			fmt.Fprintf(os.Stderr, "%s: %s\n", finding.file, finding.message)
		}
		fmt.Fprintf(os.Stderr, "doccheck: %d issue(s)\n", len(findings))
		os.Exit(1)
	}
	fmt.Printf("doccheck: %d Markdown files clean\n", markdownFiles)
}
