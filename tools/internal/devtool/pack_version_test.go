package devtool

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// The exact spellings that made this a defect: each one loads, advertises,
// persists, produces a valid pack_ref and can be signed — and is then refused
// by `packctl catalog build`, so it can never be published. Catching them at
// authoring is the whole point.
func TestPublishableVersion(t *testing.T) {
	for _, ok := range []string{"1", "1.4", "0.3.15", "10.20.30"} {
		if err := publishableVersion(ok); err != nil {
			t.Errorf("publishableVersion(%q) = %v, want nil", ok, err)
		}
	}
	for _, bad := range []string{"", "1.0.0-rc1", "2.0.0+build", "v1.2", "stable", "1.0.0.beta"} {
		if err := publishableVersion(bad); err == nil {
			t.Errorf("publishableVersion(%q) = nil, want a refusal", bad)
		}
	}
}

func TestValidatePackVersions(t *testing.T) {
	write := func(t *testing.T, body string) string {
		t.Helper()
		dir := t.TempDir()
		if err := os.WriteFile(filepath.Join(dir, "pack.yaml"), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		return dir
	}

	t.Run("a publishable version passes", func(t *testing.T) {
		dir := write(t, "schema_version: 1\nversion: 0.3.15\nretired_below: 0.3.15\n")
		if err := validatePackVersions(dir); err != nil {
			t.Errorf("validatePackVersions = %v, want nil", err)
		}
	})

	t.Run("a prerelease version is refused with its reason", func(t *testing.T) {
		dir := write(t, "schema_version: 1\nversion: 1.0.0-rc1\n")
		err := validatePackVersions(dir)
		if err == nil {
			t.Fatal("validatePackVersions accepted a version the registry cannot publish")
		}
		if !strings.Contains(err.Error(), "never reach the registry") {
			t.Errorf("error does not explain the consequence: %v", err)
		}
	})

	// The retirement floor is compared against published versions by the same
	// parser, so an unspellable floor is the same defect one field over.
	t.Run("an unpublishable retirement floor is refused", func(t *testing.T) {
		dir := write(t, "schema_version: 1\nversion: 1.0.0\nretired_below: 1.0.0-rc1\n")
		err := validatePackVersions(dir)
		if err == nil {
			t.Fatal("validatePackVersions accepted an uncomparable retired_below")
		}
		if !strings.Contains(err.Error(), "retired_below") {
			t.Errorf("error does not name the field: %v", err)
		}
	})
}

// Every pack we ship must already satisfy the lint — otherwise it is a rule
// nobody could adopt.
func TestEveryShippedPackVersionIsPublishable(t *testing.T) {
	root, err := filepath.Abs(filepath.Join("..", "..", "..", "packs"))
	if err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatal(err)
	}
	checked := 0
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		dir := filepath.Join(root, entry.Name())
		if _, err := os.Stat(filepath.Join(dir, "pack.yaml")); err != nil {
			continue
		}
		checked++
		if err := validatePackVersions(dir); err != nil {
			t.Errorf("shipped pack: %v", err)
		}
	}
	if checked == 0 {
		t.Fatal("no packs were checked; the path is wrong")
	}
}

// This lint was written to stop an unpublishable version reaching release time,
// and for a while it could not: its only call site was `./run pack check <pack>`,
// a command a person types. CI reaches packs through `./run check packs` alone,
// so `1.0.0-rc1` in packs/ passed CI green and failed at publication anyway.
//
// The rule, stated so the next per-pack lint cannot repeat it: every
// validatePack* check the single-pack command applies must also run in the
// repo-wide loop.
func TestRepoWidePackValidationRunsEveryPerPackLint(t *testing.T) {
	repoWide := packLintCalls(t, "gates.go", "validatePacks")
	perPack := packLintCalls(t, "pack.go", "pack")
	for _, lint := range perPack {
		if !slices.Contains(repoWide, lint) {
			t.Errorf("%s runs in ./run pack check but not in validatePacks, so CI never applies it", lint)
		}
	}
	// Guards the test itself: a rename that empties either side would otherwise
	// pass vacuously.
	if !slices.Contains(perPack, "validatePackVersions") {
		t.Errorf("pack check no longer applies the version lint; calls found: %v", perPack)
	}
}

// packLintCalls reports the validatePack* functions called inside one function,
// read from the source rather than executed: validatePacks builds bin/emisar and
// shells out per pack, so running it cannot say which lints it applied.
func packLintCalls(t *testing.T, file, function string) []string {
	t.Helper()
	parsed, err := parser.ParseFile(token.NewFileSet(), file, nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	var calls []string
	for _, decl := range parsed.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Name.Name != function {
			continue
		}
		ast.Inspect(fn.Body, func(node ast.Node) bool {
			call, ok := node.(*ast.CallExpr)
			if !ok {
				return true
			}
			if name, ok := call.Fun.(*ast.Ident); ok && strings.HasPrefix(name.Name, "validatePack") {
				calls = append(calls, name.Name)
			}
			return true
		})
	}
	if len(calls) == 0 {
		t.Fatalf("%s: no validatePack* calls found in %s", file, function)
	}
	slices.Sort(calls)
	return slices.Compact(calls)
}
