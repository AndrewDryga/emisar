package main

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"testing"
)

// captureStdout runs fn with os.Stdout redirected to a pipe and returns
// everything written to it. The catalog commands print results with printJSON /
// banner to the real os.Stdout (not cmd.OutOrStdout()), so cmd.SetOut can't
// observe them — a process-level redirect is the only way to assert the
// wrapper's output in-process.
func captureStdout(t *testing.T, fn func()) string {
	t.Helper()
	orig := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe: %v", err)
	}
	os.Stdout = w
	done := make(chan string, 1)
	go func() {
		var buf bytes.Buffer
		_, _ = io.Copy(&buf, r)
		done <- buf.String()
	}()
	defer func() {
		os.Stdout = orig
		_ = r.Close()
	}()
	fn()
	_ = w.Close()
	return <-done
}

// withJSONOut sets the package-global --json flag for the duration of a test
// and restores it after. The flag lives on the root command's persistent
// flags, so a subcommand built in isolation can't parse `--json` itself; the
// wrappers read this global.
func withJSONOut(t *testing.T, v bool) {
	t.Helper()
	orig := flagJSONOut
	t.Cleanup(func() { flagJSONOut = orig })
	flagJSONOut = v
}

// writeValidPack drops a minimal, loadable pack into a fresh dir under tmp
// and returns its root. The pack is the smallest shape LoadOne accepts, so
// PackHash returns a real content hash the catalog build keys off.
func writeValidPack(t *testing.T, tmp, id string) string {
	t.Helper()
	root := filepath.Join(tmp, id)
	must := func(err error) {
		if err != nil {
			t.Fatal(err)
		}
	}
	must(os.MkdirAll(filepath.Join(root, "actions"), 0o755))
	must(os.WriteFile(filepath.Join(root, "pack.yaml"), []byte(`schema_version: 1
id: `+id+`
name: t
version: 0.0.1
description: t
actions:
  - actions/a.yaml
`), 0o644))
	must(os.WriteFile(filepath.Join(root, "actions", "a.yaml"), []byte(`schema_version: 1
id: `+id+`.a
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
`), 0o644))
	return root
}
