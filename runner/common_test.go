package main

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"testing"
)

// captureStdout runs fn with os.Stdout redirected to a pipe and returns
// everything written to it. The CLI commands print results with printJSON /
// fmt.Printf to the real os.Stdout (not cmd.OutOrStdout()), so cmd.SetOut
// can't observe them — a process-level redirect is the only way to assert
// the wrapper's output in-process.
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

// TestCoerceArgValue_NoEvaluation: shell/JSON metacharacters in a plain value
// come back as a verbatim string — never executed, never structurally
// reinterpreted. Typed literals still coerce, preserving normal behavior.
func TestCoerceArgValue_NoEvaluation(t *testing.T) {
	verbatim := []string{"; rm -rf /", "$(touch /tmp/x)", "`reboot`", "--privileged", "a b c", "x;y|z"}
	for _, in := range verbatim {
		got := coerceArgValue(in)
		if s, ok := got.(string); !ok || s != in {
			t.Fatalf("coerceArgValue(%q) = %#v, want the verbatim string", in, got)
		}
	}
	if got := coerceArgValue("true"); got != true {
		t.Fatalf(`coerceArgValue("true") = %#v, want bool true`, got)
	}
	if got := coerceArgValue("42"); got != int64(42) {
		t.Fatalf(`coerceArgValue("42") = %#v, want int64 42`, got)
	}
}

// TestDefaultConfigPaths_ExcludesCwd: config auto-discovery must never search
// a cwd-relative path — otherwise an attacker who can drop a file in the
// process's working directory could supply the runner's config.
func TestDefaultConfigPaths_ExcludesCwd(t *testing.T) {
	for _, p := range defaultConfigPaths() {
		if !filepath.IsAbs(p) {
			t.Fatalf("config search path must be absolute, got cwd-relative %q", p)
		}
	}
}

// TestResolveConfigPath_Precedence: explicit --config wins over
// $EMISAR_CONFIG, which wins over the well-known locations.
func TestResolveConfigPath_Precedence(t *testing.T) {
	orig := flagConfig
	defer func() { flagConfig = orig }()
	t.Setenv("EMISAR_CONFIG", "/from/env.yaml")

	flagConfig = "/from/flag.yaml"
	if got, err := resolveConfigPath(); err != nil || got != "/from/flag.yaml" {
		t.Fatalf("--config must win: got %q err %v", got, err)
	}
	flagConfig = ""
	if got, err := resolveConfigPath(); err != nil || got != "/from/env.yaml" {
		t.Fatalf("$EMISAR_CONFIG must win when no flag: got %q err %v", got, err)
	}
}

// TestParseArgFlag_RequiresKeyEquals: an `--arg` without `=` is a hard error,
// not a silently-empty value. The error names the bad token so the operator
// can fix it. closes RUN-002-T08.
func TestParseArgFlag_RequiresKeyEquals(t *testing.T) {
	if _, err := parseArgFlag([]string{"novalue"}); err == nil {
		t.Fatal("parseArgFlag([novalue]) must error: --arg requires key=value")
	}
	// A valid pair still parses, and an empty value (trailing `=`) is allowed —
	// the `=` is what's mandatory, not a non-empty value.
	got, err := parseArgFlag([]string{"k=v", "empty="})
	if err != nil {
		t.Fatalf("parseArgFlag(valid pairs): %v", err)
	}
	if got["k"] != "v" {
		t.Fatalf(`k = %#v, want "v"`, got["k"])
	}
	if got["empty"] != "" {
		t.Fatalf(`empty = %#v, want ""`, got["empty"])
	}
	// A `=` in the value is kept verbatim — only the FIRST `=` splits key/value.
	got, err = parseArgFlag([]string{"q=a=b=c"})
	if err != nil {
		t.Fatalf("parseArgFlag(value with =): %v", err)
	}
	if got["q"] != "a=b=c" {
		t.Fatalf(`q = %#v, want "a=b=c" (only first = splits)`, got["q"])
	}
}

// writeMinimalConfig writes the smallest valid config (no cloud.url, so no
// auth-key requirement) wiring journal/cursor under dir and pointing packs at
// packDir. Returns the config path.
func writeMinimalConfig(t *testing.T, dir, packDir string) string {
	t.Helper()
	cfgPath := filepath.Join(dir, "config.yaml")
	yaml := "schema_version: 1\n" +
		"runner:\n  group: test\n" +
		"paths:\n  packs:\n    - " + packDir + "\n  data_dir: " + filepath.Join(dir, "data") + "\n" +
		"events:\n  jsonl_path: " + filepath.Join(dir, "events.jsonl") + "\n"
	if err := os.WriteFile(cfgPath, []byte(yaml), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}
	return cfgPath
}

// writePack drops a one-action pack named id under root/<id>/ and returns the
// containing dir (root). The action id is "<id>.ping".
func writePack(t *testing.T, root, id string) string {
	t.Helper()
	dir := filepath.Join(root, id)
	if err := os.MkdirAll(filepath.Join(dir, "actions"), 0o755); err != nil {
		t.Fatalf("mkdir pack: %v", err)
	}
	manifest := "schema_version: 1\nid: " + id + "\nname: " + id + "\nversion: 0.0.1\ndescription: d\nactions:\n  - actions/ping.yaml\n"
	action := "schema_version: 1\nid: " + id + ".ping\ntitle: Ping\nkind: exec\nrisk: low\ndescription: d\nside_effects: [none]\n" +
		"execution:\n  command:\n    binary: /bin/true\n    argv: []\n  timeout: 5s\n  timeout_min: 1s\n  timeout_max: 30s\n" +
		"output:\n  parser: text\n  max_stdout_bytes: 1024\n  max_stderr_bytes: 1024\n"
	if err := os.WriteFile(filepath.Join(dir, "pack.yaml"), []byte(manifest), 0o644); err != nil {
		t.Fatalf("write pack.yaml: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "actions", "ping.yaml"), []byte(action), 0o644); err != nil {
		t.Fatalf("write action: %v", err)
	}
	return root
}

// withFlags saves and restores the package-global CLI flags boot() reads, so a
// test can set them without leaking into other tests.
func withFlags(t *testing.T) {
	t.Helper()
	origConfig, origPacks := flagConfig, flagPacksDir
	t.Cleanup(func() { flagConfig, flagPacksDir = origConfig, origPacks })
	// Auto-discovery must not pick up a real /etc/emisar/config.yaml on the dev
	// box; force resolution through the explicit flag/env each test sets.
	t.Setenv("EMISAR_CONFIG", "")
}

// TestBoot_PacksDirFlagOverridesConfig: when --packs-dir is given, boot() loads
// packs from the flag dirs and ignores cfg.Paths.Packs entirely (common.go
// packDirs selection). closes RUN-002-T02.
func TestBoot_PacksDirFlagOverridesConfig(t *testing.T) {
	withFlags(t)
	dir := t.TempDir()

	configPacks := writePack(t, filepath.Join(dir, "cfgpacks"), "fromconfig")
	flagPacks := writePack(t, filepath.Join(dir, "flagpacks"), "fromflag")

	flagConfig = writeMinimalConfig(t, dir, configPacks)
	flagPacksDir = []string{flagPacks}

	rt, err := boot()
	if err != nil {
		t.Fatalf("boot: %v", err)
	}
	defer rt.journal.Close()

	if _, ok := rt.registry().Action("fromflag.ping"); !ok {
		t.Fatalf("--packs-dir pack not loaded; actions=%v", actionIDs(rt))
	}
	if _, ok := rt.registry().Action("fromconfig.ping"); ok {
		t.Fatalf("config packs must be ignored when --packs-dir is set; actions=%v", actionIDs(rt))
	}
}

func actionIDs(rt *runtime) []string {
	var ids []string
	for _, a := range rt.registry().Actions() {
		ids = append(ids, a.ID)
	}
	return ids
}

// TestResolveConfigPath_WellKnownMustBeRegularFile: auto-discovery only accepts
// a regular file at a well-known path — a directory there must NOT win, and
// with no flag/env set resolution falls through to the no-config error.
// closes RUN-002-T05.
func TestResolveConfigPath_WellKnownMustBeRegularFile(t *testing.T) {
	if isRegularFile(t.TempDir()) {
		t.Fatal("isRegularFile must reject a directory")
	}
	f := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(f, []byte("schema_version: 1\n"), 0o600); err != nil {
		t.Fatalf("write file: %v", err)
	}
	if !isRegularFile(f) {
		t.Fatal("isRegularFile must accept a regular file")
	}
}

// TestResolveConfigPath_NoConfigAnywhere: with no --config, no $EMISAR_CONFIG,
// and no well-known file, resolution is a hard error that names where it
// looked — before boot() touches anything. closes RUN-002-T06.
func TestResolveConfigPath_NoConfigAnywhere(t *testing.T) {
	withFlags(t)
	flagConfig = ""
	// Point HOME at an empty dir so the per-user well-known path doesn't exist;
	// the /etc path won't exist on a clean checkout either.
	t.Setenv("HOME", t.TempDir())

	_, err := resolveConfigPath()
	if err == nil {
		t.Fatal("resolveConfigPath must error when no config is discoverable")
	}
	for _, want := range []string{"EMISAR_CONFIG", "--config"} {
		if !contains(err.Error(), want) {
			t.Fatalf("error %q should mention %q (where it looked / how to fix)", err, want)
		}
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

// An explicit --config value is returned as-is, never stat-checked, so a
// missing path wins resolution and the open failure is reported later by
// config.Load (through boot) — not silently swallowed by discovery falling
// through to a well-known file. closes RUN-002-T04.
func TestResolveConfigPath_ExplicitValueReturnedUnstatted(t *testing.T) {
	// closes RUN-002-T04
	withFlags(t)
	missing := filepath.Join(t.TempDir(), "nope.yaml")
	flagConfig = missing

	// resolveConfigPath returns the path verbatim, with no error — it does not
	// stat it (unlike auto-discovery, which requires a regular file to win).
	got, err := resolveConfigPath()
	if err != nil {
		t.Fatalf("explicit --config must resolve without error: %v", err)
	}
	if got != missing {
		t.Fatalf("explicit --config = %q, want it returned as-is %q", got, missing)
	}
	// boot() then surfaces the open failure (the file genuinely doesn't exist).
	if _, err := boot(); err == nil {
		t.Fatal("boot() over a missing explicit --config must error at config.Load")
	}
}

// A pack dir that doesn't exist is skipped silently by LoadAll: boot()
// succeeds and the registry is simply empty, rather than failing the whole
// runner because one configured dir is absent (a typo is surfaced by `doctor`,
// not by refusing to boot). closes RUN-002-T07.
func TestBoot_MissingPackDirSkippedSilently(t *testing.T) {
	// closes RUN-002-T07
	withFlags(t)
	dir := t.TempDir()
	// A real config, but --packs-dir points only at a path that doesn't exist.
	flagConfig = writeMinimalConfig(t, dir, filepath.Join(dir, "packs"))
	flagPacksDir = []string{filepath.Join(dir, "does-not-exist")}

	rt, err := boot()
	if err != nil {
		t.Fatalf("a missing pack dir must be skipped, not fail boot: %v", err)
	}
	defer rt.journal.Close()
	if got := len(rt.registry().Actions()); got != 0 {
		t.Fatalf("a missing pack dir should load no actions, got %d", got)
	}
}

// A malformed admission glob (an unterminated char-class) is rejected by
// boot(): config.Load doesn't validate the globs, so the error surfaces when
// admission.New compiles them, wrapped as `admission: …` (common.go). A bad
// pattern must fail at boot, not silently admit/deny nothing at first request.
// closes RUN-002-T12.
func TestBoot_AdmissionCompileErrorWrapped(t *testing.T) {
	// closes RUN-002-T12
	withFlags(t)
	dir := t.TempDir()
	packDir := writePack(t, filepath.Join(dir, "packs"), "linux")
	cfgPath := filepath.Join(dir, "config.yaml")
	yaml := "schema_version: 1\n" +
		"runner:\n  group: test\n" +
		"paths:\n  packs:\n    - " + packDir + "\n  data_dir: " + filepath.Join(dir, "data") + "\n" +
		"events:\n  jsonl_path: " + filepath.Join(dir, "events.jsonl") + "\n" +
		// `[` is an unterminated character class — filepath.Match rejects it.
		"admission:\n  deny:\n    - \"linux.[\"\n"
	if err := os.WriteFile(cfgPath, []byte(yaml), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}
	flagConfig = cfgPath

	_, err := boot()
	if err == nil {
		t.Fatal("boot() must reject a malformed admission glob")
	}
	if !contains(err.Error(), "admission") {
		t.Fatalf("the error should be wrapped as an admission failure, got %q", err)
	}
}
