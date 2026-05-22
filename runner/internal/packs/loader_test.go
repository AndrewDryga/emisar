package packs

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

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
    binary: /bin/echo
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
    binary: /bin/echo
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
