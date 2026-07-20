package packs

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoad_NormalizesOutputSchema(t *testing.T) {
	action := strings.Replace(actionYAML("testpack.a"), `  parser: text`, `  parser: json
  parser_required: true
  schema:
    type: object
    properties:
      ratio:
        type: number
        const: 0.5
    required: [ratio]
    additionalProperties: false`, 1)
	root := writePack(t, t.TempDir(), "p", map[string]string{
		"pack.yaml":      packYAML("testpack"),
		"actions/a.yaml": action,
	})

	reg, err := LoadOne(root, LoadOptions{})
	if err != nil {
		t.Fatal(err)
	}
	loaded, ok := reg.Action("testpack.a")
	if !ok {
		t.Fatal("action not registered")
	}
	constant := loaded.Output.Schema["properties"].(map[string]any)["ratio"].(map[string]any)["const"]
	if got, isNumber := constant.(json.Number); !isNumber || got.String() != "0.5" {
		t.Fatalf("const = %#v, want normalized json.Number 0.5", constant)
	}
	encoded, err := json.Marshal(loaded.ModelDescriptor())
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(encoded), `"const":0.5`) {
		t.Fatalf("descriptor lost the schema literal: %s", encoded)
	}
	validator, ok := reg.OutputSchema("testpack.a")
	if !ok {
		t.Fatal("output validator not registered")
	}
	if _, _, outputErr := validator.Validate([]byte(`{"ratio":0.5}`)); outputErr != nil {
		t.Fatalf("conforming result rejected: %v", outputErr)
	}
	if _, _, outputErr := validator.Validate([]byte(`{"ratio":0.25}`)); outputErr == nil {
		t.Fatal("non-conforming result accepted")
	}
}

func TestLoad_RejectsNonCanonicalOutputSchemaNumbers(t *testing.T) {
	action := strings.Replace(actionYAML("testpack.a"), `  parser: text`, `  parser: json
  parser_required: true
  schema:
    type: object
    properties:
      count: {type: integer, maximum: 9007199254740993}`, 1)
	root := writePack(t, t.TempDir(), "p", map[string]string{
		"pack.yaml":      packYAML("testpack"),
		"actions/a.yaml": action,
	})

	if _, err := LoadOne(root, LoadOptions{}); err == nil || !strings.Contains(err.Error(), "float64 round trip") {
		t.Fatalf("non-canonical schema number should fail pack loading, got %v", err)
	}
}

func writePack(t *testing.T, tmp, name string, files map[string]string) string {
	t.Helper()
	root := filepath.Join(tmp, name)
	for rel, body := range files {
		full := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

const validAction = `
schema_version: 1
id: %s
title: t
kind: exec
risk: low
description: d
side_effects: [none]
args: []
execution:
  command:
    binary: echo
    argv: ["hi"]
  timeout: 5s
output:
  parser: text
  max_stdout_bytes: 1024
  max_stderr_bytes: 1024
`

func actionYAML(id string) string {
	return strings.Replace(validAction, "%s", id, 1)
}

func packYAML(id string) string {
	return `schema_version: 1
id: ` + id + `
name: t
version: 0.0.1
description: t
actions:
  - actions/a.yaml
`
}

func TestLoad_SetupVerify(t *testing.T) {
	packWithVerify := func(verify string) string {
		return `schema_version: 1
id: vp
name: t
version: 0.0.1
description: t
setup:
  verify: ` + verify + `
actions:
  - actions/a.yaml
`
	}

	t.Run("valid verify resolves", func(t *testing.T) {
		root := writePack(t, t.TempDir(), "p", map[string]string{
			"pack.yaml":      packWithVerify("vp.a"),
			"actions/a.yaml": actionYAML("vp.a"),
		})
		if _, err := LoadOne(root, LoadOptions{}); err != nil {
			t.Fatalf("valid verify should load: %v", err)
		}
	})

	t.Run("unknown verify fails", func(t *testing.T) {
		root := writePack(t, t.TempDir(), "p", map[string]string{
			"pack.yaml":      packWithVerify("vp.missing"),
			"actions/a.yaml": actionYAML("vp.a"),
		})
		if _, err := LoadOne(root, LoadOptions{}); err == nil {
			t.Fatal("unknown verify action should fail to load")
		}
	})
}

func TestLoad_ValidPack(t *testing.T) {
	tmp := t.TempDir()
	root := writePack(t, tmp, "p", map[string]string{
		"pack.yaml":      packYAML("testpack"),
		"actions/a.yaml": actionYAML("testpack.a"),
	})
	reg, err := LoadOne(root, LoadOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := reg.Action("testpack.a"); !ok {
		t.Fatal("action not registered")
	}
	if h, ok := reg.PackHash("testpack"); !ok || h == "" {
		t.Fatal("pack hash should be set")
	}
}

func TestLoad_RejectsInexactIntegerBound(t *testing.T) {
	action := strings.Replace(actionYAML("testpack.a"), "args: []", `args:
  - name: value
    type: integer
    validation:
      max: 891234567890123456`, 1)
	root := writePack(t, t.TempDir(), "p", map[string]string{
		"pack.yaml":      packYAML("testpack"),
		"actions/a.yaml": action,
	})

	if _, err := LoadOne(root, LoadOptions{}); err == nil || !strings.Contains(err.Error(), "exactly represented integer") {
		t.Fatalf("inexact integer bound should fail pack loading, got %v", err)
	}
}

func TestLoad_DuplicateActionIDsAcrossPacks(t *testing.T) {
	tmp := t.TempDir()
	writePack(t, tmp, "one", map[string]string{
		"pack.yaml":      packYAML("one"),
		"actions/a.yaml": actionYAML("dup.id"),
	})
	writePack(t, tmp, "two", map[string]string{
		"pack.yaml":      packYAML("two"),
		"actions/a.yaml": actionYAML("dup.id"),
	})
	_, err := LoadAll([]string{tmp}, LoadOptions{})
	if err == nil || !strings.Contains(err.Error(), "duplicate action id") {
		t.Fatalf("expected duplicate action id error, got %v", err)
	}
}

func TestLoadAll_IgnoresHiddenReplacementDirectories(t *testing.T) {
	tmp := t.TempDir()
	writePack(t, tmp, "visible", map[string]string{
		"pack.yaml":      packYAML("visible"),
		"actions/a.yaml": actionYAML("visible.a"),
	})
	writePack(t, tmp, ".visible.stage-incomplete", map[string]string{
		"pack.yaml": "not valid pack yaml",
	})
	writePack(t, tmp, ".visible.previous", map[string]string{
		"pack.yaml": "also invalid",
	})

	reg, err := LoadAll([]string{tmp}, LoadOptions{})
	if err != nil {
		t.Fatalf("hidden replacement directories reached the loader: %v", err)
	}
	if loaded := reg.Packs(); len(loaded) != 1 || loaded[0].ID != "visible" {
		t.Fatalf("loaded packs=%v, want only visible", loaded)
	}
}

// One unparseable installed pack once crash-looped a production runner 1,164
// times (boot-fatal LoadAll under systemd Restart=always), taking every
// healthy pack's incident-response surface down with it. Under
// SkipBrokenPacks the daemon degrades that pack and serves the rest.
func TestLoadAll_SkipBrokenPacksDegradesInsteadOfFailing(t *testing.T) {
	tmp := t.TempDir()
	writePack(t, tmp, "good", map[string]string{
		"pack.yaml":      packYAML("good"),
		"actions/a.yaml": actionYAML("good.a"),
	})
	broken := writePack(t, tmp, "broken", map[string]string{
		"pack.yaml":      packYAML("broken"),
		"actions/a.yaml": "unknown_field: true\n" + actionYAML("broken.a"),
	})

	// Default stays fail-fast — the publisher must never silently drop a pack.
	if _, err := LoadAll([]string{tmp}, LoadOptions{}); err == nil {
		t.Fatal("default load accepted a broken pack")
	}

	reg, err := LoadAll([]string{tmp}, LoadOptions{SkipBrokenPacks: true})
	if err != nil {
		t.Fatalf("SkipBrokenPacks load failed the whole registry: %v", err)
	}
	if loaded := reg.Packs(); len(loaded) != 1 || loaded[0].ID != "good" {
		t.Fatalf("loaded packs=%v, want only good", loaded)
	}
	degraded := reg.Degraded()
	if len(degraded) != 1 || degraded[0].Dir != broken || degraded[0].Reason == "" {
		t.Fatalf("degraded=%v, want the broken pack dir with a reason", degraded)
	}
}

// A pack that fails part-way through insertion (the manifest parsed; an
// action file did not) must leave no trace — a half-loaded pack advertises
// actions its content hash can never match.
func TestLoadAll_SkipBrokenPacksRemovesPartialInsertion(t *testing.T) {
	tmp := t.TempDir()
	writePack(t, tmp, "partial", map[string]string{
		"pack.yaml": `schema_version: 1
id: partial
name: t
version: 0.0.1
description: t
actions:
  - actions/a.yaml
  - actions/b.yaml
`,
		"actions/a.yaml": actionYAML("partial.a"),
		"actions/b.yaml": "not: [valid",
	})

	reg, err := LoadAll([]string{tmp}, LoadOptions{SkipBrokenPacks: true})
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if len(reg.Packs()) != 0 {
		t.Fatalf("half-loaded pack left in the registry: %v", reg.Packs())
	}
	if _, ok := reg.Action("partial.a"); ok {
		t.Fatal("half-loaded pack left an action registered")
	}
	if len(reg.Degraded()) != 1 {
		t.Fatalf("degraded=%v, want exactly the partial pack", reg.Degraded())
	}
}

func TestLoad_MultiLevelNamespaceAllowed(t *testing.T) {
	tmp := t.TempDir()
	root := writePack(t, tmp, "p", map[string]string{
		"pack.yaml":      packYAML("myorg.things"),
		"actions/a.yaml": actionYAML("myorg.things.do_it"),
	})
	reg, err := LoadOne(root, LoadOptions{})
	if err != nil {
		t.Fatalf("expected to load, got %v", err)
	}
	if _, ok := reg.Action("myorg.things.do_it"); !ok {
		t.Fatal("namespaced action not registered")
	}
}

func TestLoad_SingleSegmentIdRejected(t *testing.T) {
	tmp := t.TempDir()
	root := writePack(t, tmp, "p", map[string]string{
		"pack.yaml":      packYAML("p"),
		"actions/a.yaml": actionYAML("noNamespace"),
	})
	_, err := LoadOne(root, LoadOptions{})
	if err == nil {
		t.Fatal("expected invalid id error (must contain a dot)")
	}
}

func TestLoad_ScriptEscapeRejected(t *testing.T) {
	tmp := t.TempDir()
	scriptAction := `
schema_version: 1
id: x.run
title: t
kind: script
risk: low
description: d
side_effects: [none]
args: []
execution:
  script:
    path: ../../../etc/passwd
    interpreter: /bin/bash
  argv: []
  timeout: 5s
output:
  parser: text
  max_stdout_bytes: 1024
  max_stderr_bytes: 1024
`
	root := writePack(t, tmp, "p", map[string]string{
		"pack.yaml":      packYAML("p"),
		"actions/a.yaml": scriptAction,
	})
	_, err := LoadOne(root, LoadOptions{})
	if err == nil || !strings.Contains(err.Error(), "escapes pack root") {
		t.Fatalf("expected pack-root escape error, got %v", err)
	}
}

func TestLoad_TimeoutBoundsEnforced(t *testing.T) {
	tmp := t.TempDir()
	bad := `
schema_version: 1
id: p.bad
title: t
kind: exec
risk: low
description: d
side_effects: [none]
args: []
execution:
  command:
    binary: echo
    argv: []
  timeout: 30s
  timeout_min: 1m
  timeout_max: 2m
output:
  parser: text
  max_stdout_bytes: 1024
  max_stderr_bytes: 1024
`
	root := writePack(t, tmp, "p", map[string]string{
		"pack.yaml":      packYAML("p"),
		"actions/a.yaml": bad,
	})
	_, err := LoadOne(root, LoadOptions{})
	if err == nil || !strings.Contains(err.Error(), "timeout") {
		t.Fatalf("expected timeout-bounds error, got %v", err)
	}
}
