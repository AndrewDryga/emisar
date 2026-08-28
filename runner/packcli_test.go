package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/andrewdryga/emisar/runner/pkg/packspec"
)

// withPacksDir points the read-only pack commands at dir via the global
// --packs-dir flag, so `pack list`/`info` resolve without a full config.
// Also clears EMISAR_CONFIG so resolvePackDirs can't fall back to a real
// /etc config on the dev box.
func withPacksDir(t *testing.T, dirs ...string) {
	t.Helper()
	origPacks, origConfig := flagPacksDir, flagConfig
	t.Cleanup(func() { flagPacksDir, flagConfig = origPacks, origConfig })
	t.Setenv("EMISAR_CONFIG", "")
	flagPacksDir = dirs
	flagConfig = ""
}

// `emisar pack list` renders installed packs as a table: id, version, action
// count, short hash, description. Driven read-only through --packs-dir (no
// config / boot) against one valid pack.
func TestPackListCmd_Table(t *testing.T) {
	root := t.TempDir()
	writeValidPack(t, root, "redis")
	withPacksDir(t, root)
	withJSONOut(t, false)

	var execErr error
	out := captureStdout(t, func() {
		cmd := packListCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("pack list: %v", execErr)
	}
	for _, want := range []string{"ID", "VERSION", "ACTIONS", "HASH", "redis", "0.0.1", "sha256:"} {
		if !strings.Contains(out, want) {
			t.Fatalf("pack list table missing %q:\n%s", want, out)
		}
	}
}

// `pack list --json` prints the full pack structs. Decoded as raw maps — not
// back into packspec.Pack, which would pass whatever the tags say — so the
// KEYS a fleet script parses are pinned to the documented snake_case shape.
func TestPackListCmd_JSON(t *testing.T) {
	root := t.TempDir()
	writeValidPack(t, root, "redis")
	withPacksDir(t, root)
	withJSONOut(t, true)

	var execErr error
	out := captureStdout(t, func() {
		cmd := packListCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("pack list --json: %v", execErr)
	}
	var ps []map[string]any
	if err := json.Unmarshal([]byte(out), &ps); err != nil {
		t.Fatalf("--json output is not a pack array: %v\n%s", err, out)
	}
	if len(ps) != 1 {
		t.Fatalf("want one pack, got %d:\n%s", len(ps), out)
	}
	assertPackJSONShape(t, ps[0])
}

// assertPackJSONShape pins the documented pack payload: snake_case keys, no
// PascalCase Go field names, and no loader-stamped host path.
func assertPackJSONShape(t *testing.T, pack map[string]any) {
	t.Helper()
	if pack["id"] != "redis" {
		t.Errorf(`id = %#v, want "redis"`, pack["id"])
	}
	if pack["version"] != "0.0.1" {
		t.Errorf(`version = %#v, want "0.0.1"`, pack["version"])
	}
	for _, want := range []string{"schema_version", "name", "description", "actions", "requires", "setup"} {
		if _, ok := pack[want]; !ok {
			t.Errorf("payload missing %q key: %v", want, keysOf(pack))
		}
	}
	// The legacy PascalCase spelling (untagged exported fields) must be gone,
	// and the loader's pack Root must never have been in the document.
	for _, forbidden := range []string{"ID", "SchemaVersion", "RetiredBelow", "AllowSymlinks", "Root", "root"} {
		if _, ok := pack[forbidden]; ok {
			t.Errorf("payload must not carry %q: %v", forbidden, keysOf(pack))
		}
	}
}

// `pack list --packs-dir` works without any config (read-only path). Pointing
// at an empty dir yields just the header row, no pack rows.
// (no-config read) and (empty dir).
func TestPackListCmd_EmptyDirNoConfig(t *testing.T) {
	empty := t.TempDir()
	withPacksDir(t, empty)
	withJSONOut(t, false)

	var execErr error
	out := captureStdout(t, func() {
		cmd := packListCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("pack list (empty dir): %v", execErr)
	}
	if !strings.Contains(out, "ID") {
		t.Fatalf("expected the header row:\n%s", out)
	}
	// No pack id rows.
	if strings.Contains(out, "0.0.1") {
		t.Fatalf("empty dir should list no packs:\n%s", out)
	}
}

// `pack list` with neither --packs-dir nor a resolvable config is a hard
// error that wraps the config-resolution failure (so the operator knows to
// pass --packs-dir or --config).
func TestPackListCmd_NoDirNoConfigErrors(t *testing.T) {
	origPacks, origConfig := flagPacksDir, flagConfig
	t.Cleanup(func() { flagPacksDir, flagConfig = origPacks, origConfig })
	flagPacksDir = nil
	flagConfig = ""
	t.Setenv("EMISAR_CONFIG", "")
	t.Setenv("HOME", t.TempDir()) // no well-known per-user config either

	cmd := packListCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	err := cmd.Execute()
	if err == nil {
		t.Fatal("pack list with no --packs-dir and no config must error")
	}
	if !strings.Contains(err.Error(), "packs-dir") {
		t.Fatalf("error %q should tell the operator to pass --packs-dir", err)
	}
}

// `pack list` surfaces a load error when the packs dir holds a malformed pack:
// LoadAll fails and the command returns that error (exit 1) rather than
// silently listing nothing.
func TestPackListCmd_MalformedPackErrors(t *testing.T) {
	root := t.TempDir()
	// A pack dir with a pack.yaml that references an action file declaring a
	// single-segment id (no pack prefix) — LoadAll rejects it.
	packDir := filepath.Join(root, "broken")
	if err := os.MkdirAll(filepath.Join(packDir, "actions"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packDir, "pack.yaml"), []byte(
		"schema_version: 1\nid: broken\nname: t\nversion: 0.0.1\ndescription: t\nactions:\n  - actions/a.yaml\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packDir, "actions", "a.yaml"), []byte(
		"schema_version: 1\nid: ping\ntitle: t\nkind: exec\nrisk: low\ndescription: d\nside_effects: [none]\nargs: []\n"+
			"execution:\n  command:\n    binary: echo\n    argv: []\n  timeout: 5s\n"+
			"output:\n  parser: text\n  max_stdout_bytes: 1024\n  max_stderr_bytes: 1024\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	withPacksDir(t, root)
	withJSONOut(t, false)

	cmd := packListCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	if err := cmd.Execute(); err == nil {
		t.Fatal("pack list must surface a malformed-pack load error")
	}
}

// `pack info <id>` prints the operator summary: header line with id/name/
// version, the action+risk profile, and — for a pack with no setup block —
// the honest "no credentials needed" line. Read-only via --packs-dir.
// (summary) and (no-setup message).
func TestPackInfoCmd_Summary(t *testing.T) {
	root := t.TempDir()
	writeValidPack(t, root, "redis")
	withPacksDir(t, root)
	withJSONOut(t, false)

	var execErr error
	out := captureStdout(t, func() {
		cmd := packInfoCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs([]string{"redis"})
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("pack info: %v", execErr)
	}
	for _, want := range []string{"redis", "v0.0.1", "Actions:", "Setup", "No credentials needed"} {
		if !strings.Contains(out, want) {
			t.Fatalf("pack info summary missing %q:\n%s", want, out)
		}
	}
}

// `pack info <id> --json` prints the full pack struct instead of the human
// summary.
func TestPackInfoCmd_JSON(t *testing.T) {
	root := t.TempDir()
	writeValidPack(t, root, "redis")
	withPacksDir(t, root)
	withJSONOut(t, true)

	var execErr error
	out := captureStdout(t, func() {
		cmd := packInfoCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs([]string{"redis"})
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("pack info --json: %v", execErr)
	}
	var p map[string]any
	if err := json.Unmarshal([]byte(out), &p); err != nil {
		t.Fatalf("--json output is not a pack struct: %v\n%s", err, out)
	}
	assertPackJSONShape(t, p)
}

// `pack info <unknown>` errors, naming the id and where it looked.
func TestPackInfoCmd_NotInstalled(t *testing.T) {
	root := t.TempDir()
	writeValidPack(t, root, "redis")
	withPacksDir(t, root)
	withJSONOut(t, false)

	cmd := packInfoCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{"nope"})
	err := cmd.Execute()
	if err == nil {
		t.Fatal("pack info for an uninstalled pack must error")
	}
	if !strings.Contains(err.Error(), "nope") || !strings.Contains(err.Error(), "not installed") {
		t.Fatalf("error %q should say the pack isn't installed", err)
	}
}

// `pack info <id>` with no resolvable config renders best-effort — it skips
// the "missing from inherit_env" cross-check entirely (that check needs a
// config to know the runner's inherit_env). The env block still prints, but
// the "! Required vars not in this config's inherit_env" warning does not, even
// for a required var.
func TestPackInfoCmd_NoConfigSkipsInheritEnvCrossCheck(t *testing.T) {
	root := t.TempDir()
	// A pack whose setup declares a REQUIRED env var. With a config, an empty
	// inherit_env would flag PGHOST; without one, the cross-check is skipped.
	packDir := filepath.Join(root, "withenv")
	if err := os.MkdirAll(filepath.Join(packDir, "actions"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packDir, "pack.yaml"), []byte(
		"schema_version: 1\nid: withenv\nname: t\nversion: 0.0.1\ndescription: t\n"+
			"setup:\n  summary: needs a host\n  env:\n    - name: PGHOST\n      required: true\n"+
			"actions:\n  - actions/a.yaml\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packDir, "actions", "a.yaml"), []byte(
		"schema_version: 1\nid: withenv.a\ntitle: t\nkind: exec\nrisk: low\ndescription: d\nside_effects: [none]\nargs: []\n"+
			"execution:\n  command:\n    binary: echo\n    argv: [\"hi\"]\n  timeout: 5s\n"+
			"output:\n  parser: text\n  max_stdout_bytes: 1024\n  max_stderr_bytes: 1024\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	// --packs-dir set, no config (withPacksDir clears EMISAR_CONFIG + flagConfig).
	withPacksDir(t, root)
	t.Setenv("HOME", t.TempDir()) // and no well-known per-user config to discover
	withJSONOut(t, false)

	var execErr error
	out := captureStdout(t, func() {
		cmd := packInfoCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs([]string{"withenv"})
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("pack info (no config): %v", execErr)
	}
	// The env var is still documented in the Environment block...
	if !strings.Contains(out, "PGHOST") {
		t.Fatalf("the env block should still list the var:\n%s", out)
	}
	// ...but the inherit_env cross-check warning is suppressed (no config).
	if strings.Contains(out, "not in this config's inherit_env") {
		t.Fatalf("no-config pack info must skip the inherit_env cross-check:\n%s", out)
	}
}

// `pack info` enforces ExactArgs(1): zero or two positional args is a cobra
// arg-count error, surfaced before any pack load.
func TestPackInfoCmd_ExactArgs(t *testing.T) {
	for _, args := range [][]string{{}, {"a", "b"}} {
		cmd := packInfoCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs(args)
		if err := cmd.Execute(); err == nil {
			t.Fatalf("pack info with %d args must be an arg-count error", len(args))
		}
	}
}

// `emisar pack validate ./pack` prints a machine-parseable OK line and the
// content hash to stdout for a valid pack. Driven on a path from t.TempDir(),
// no config/network.
func TestPackValidateCmd_OK(t *testing.T) {
	src := writeValidPack(t, t.TempDir(), "redis")

	var execErr error
	out := captureStdout(t, func() {
		cmd := packValidateCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs([]string{src})
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("pack validate: %v", execErr)
	}
	if !strings.Contains(out, "pack redis OK: 1 actions") {
		t.Fatalf("validate should print the OK line with the action count:\n%s", out)
	}
	if !strings.Contains(out, "hash: sha256:") {
		t.Fatalf("validate should print the content hash:\n%s", out)
	}
}

// `pack validate` on a schema-broken pack errors (exit 1) with the loader's
// reason. Here: an action whose id is a single segment (no pack prefix),
// which LoadOne rejects.
func TestPackValidateCmd_InvalidPackErrors(t *testing.T) {
	root := filepath.Join(t.TempDir(), "broken")
	if err := os.MkdirAll(filepath.Join(root, "actions"), 0o755); err != nil {
		t.Fatal(err)
	}
	// id "broken" with an action id "ping" (no "broken." prefix) — a
	// single-segment action id the loader refuses.
	if err := os.WriteFile(filepath.Join(root, "pack.yaml"), []byte(
		"schema_version: 1\nid: broken\nname: t\nversion: 0.0.1\ndescription: t\nactions:\n  - actions/a.yaml\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "actions", "a.yaml"), []byte(
		"schema_version: 1\nid: ping\ntitle: t\nkind: exec\nrisk: low\ndescription: d\nside_effects: [none]\nargs: []\n"+
			"execution:\n  command:\n    binary: echo\n    argv: []\n  timeout: 5s\n"+
			"output:\n  parser: text\n  max_stdout_bytes: 1024\n  max_stderr_bytes: 1024\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	cmd := packValidateCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{root})
	if err := cmd.Execute(); err == nil {
		t.Fatal("pack validate of a schema-broken pack must error")
	}
}

// `pack validate` enforces ExactArgs(1): zero or two paths is a cobra
// arg-count error.
func TestPackValidateCmd_ExactArgs(t *testing.T) {
	for _, args := range [][]string{{}, {"a", "b"}} {
		cmd := packValidateCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs(args)
		if err := cmd.Execute(); err == nil {
			t.Fatalf("validate with %d args must be an arg-count error", len(args))
		}
	}
}

// Pack setup text carries light markdown so the public pack page can format
// it. In a terminal that markup is noise, and a link left inline is worse than
// noise: wrapText breaks it mid-URL, so it is neither clickable nor copyable —
// the only reason to print it at all.
func TestSetupProse_StripsCodeTicksAndLiftsLinksOut(t *testing.T) {
	tests := []struct {
		name      string
		in        string
		wantProse string
		wantLinks []string
	}{
		{
			name:      "plain text is untouched",
			in:        "Set it on the runner host.",
			wantProse: "Set it on the runner host.",
		},
		{
			name:      "code ticks are dropped, not styled",
			in:        "add `GH_TOKEN` to `execution.inherit_env`",
			wantProse: "add GH_TOKEN to execution.inherit_env",
		},
		{
			name:      "a link leaves its label behind and its URL comes back separately",
			in:        "[Create a token](https://github.com/settings/tokens/new?scopes=repo) first.",
			wantProse: "Create a token first.",
			wantLinks: []string{"https://github.com/settings/tokens/new?scopes=repo"},
		},
		{
			name:      "only https is treated as a link",
			in:        "see [x](javascript:alert(1)) and [y](http://plain.example)",
			wantProse: "see [x](javascript:alert(1)) and [y](http://plain.example)",
		},
		{
			name:      "an example URL in prose is not a link and survives intact",
			in:        "as `https://ACCESS:SECRET@endpoint`",
			wantProse: "as https://ACCESS:SECRET@endpoint",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			prose, links := setupProse(test.in)
			if prose != test.wantProse {
				t.Errorf("prose = %q, want %q", prose, test.wantProse)
			}
			if len(links) != len(test.wantLinks) {
				t.Fatalf("links = %v, want %v", links, test.wantLinks)
			}
			for i, want := range test.wantLinks {
				if links[i] != want {
					t.Errorf("links[%d] = %q, want %q", i, links[i], want)
				}
			}
		})
	}
}

// The whole point of lifting the URL out: it must reach the operator unbroken.
func TestWriteSetup_PrintsAnAuthoredURLOnOneUnwrappedLine(t *testing.T) {
	url := "https://github.com/settings/tokens/new?scopes=repo&description=emisar%20runner"
	var out strings.Builder
	writeSetup(&out, newStyler(&out), &packspec.Pack{
		Setup: packspec.Setup{
			Notes: []string{"[Create a classic token with the repo scope preselected](" + url +
				"). Classic tokens have no read-only repo scope, so repo is the floor here."},
		},
	}, nil, false)

	if !strings.Contains(out.String(), url) {
		t.Fatalf("the URL must survive whole; got:\n%s", out.String())
	}
	for _, line := range strings.Split(out.String(), "\n") {
		if strings.Contains(line, "github.com") && strings.TrimSpace(line) != url {
			t.Errorf("URL line carries more than the URL (so it was wrapped or inlined): %q", line)
		}
	}
	if strings.Contains(out.String(), "](") {
		t.Error("markdown link syntax leaked into terminal output")
	}
}

func TestWriteSetup_PrintsHostAccessRecipesWithoutChangingCommands(t *testing.T) {
	command := "  sudo install -m 0640 /var/log/service.log /run/emisar/service.log  "
	var out strings.Builder
	writeSetup(&out, newStyler(&out), &packspec.Pack{
		Setup: packspec.Setup{
			HostAccess: []packspec.HostAccess{{
				Actions:     []string{"service.logs", "service.status"},
				Requirement: "Read the service log.",
				Recipes: []packspec.HostAccessRecipe{{
					Name:     "Debian and Ubuntu",
					Commands: []string{command},
					Verify:   []string{"sudo -u emisar test -r /run/emisar/service.log"},
					Impact:   "Lets both listed actions read the log.",
				}},
			}},
		},
	}, nil, false)

	printed := out.String()
	for _, want := range []string{
		"Host access:",
		"Emisar never runs",
		"setup recipes.",
		"Actions: service.logs, service.status",
		"Debian and Ubuntu",
		command,
		"Verify:",
		"Impact: Lets both listed actions read the log.",
	} {
		if !strings.Contains(printed, want) {
			t.Errorf("host-access output missing %q:\n%s", want, printed)
		}
	}
}

// The runner never DERIVES a pack page URL — a self-hosted registry's packs do
// not live on our site — so the link comes from the pack's own homepage field,
// and a pack that declares none gets no Docs line at all.
func TestWritePackInfo_DocsLineComesFromThePackOrIsAbsent(t *testing.T) {
	root := t.TempDir()
	write := func(id, extra string) {
		dir := filepath.Join(root, id)
		if err := os.MkdirAll(filepath.Join(dir, "actions"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "pack.yaml"), []byte(
			"schema_version: 1\nid: "+id+"\nname: t\nversion: 0.0.1\ndescription: t\n"+extra+
				"actions:\n  - actions/a.yaml\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "actions", "a.yaml"), []byte(
			"schema_version: 1\nid: "+id+".a\ntitle: t\nkind: exec\nrisk: low\ndescription: d\nside_effects: [none]\nargs: []\n"+
				"execution:\n  command:\n    binary: echo\n    argv: [\"hi\"]\n  timeout: 5s\n"+
				"output:\n  parser: text\n  max_stdout_bytes: 1024\n  max_stderr_bytes: 1024\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("withdocs", "homepage: https://emisar.dev/packs/withdocs\n")
	write("nodocs", "")

	withPacksDir(t, root)
	t.Setenv("HOME", t.TempDir())
	withJSONOut(t, false)

	info := func(id string) string {
		var execErr error
		out := captureStdout(t, func() {
			cmd := packInfoCmd()
			cmd.SilenceUsage, cmd.SilenceErrors = true, true
			cmd.SetArgs([]string{id})
			execErr = cmd.Execute()
		})
		if execErr != nil {
			t.Fatalf("pack info %s: %v", id, execErr)
		}
		return out
	}

	shown := info("withdocs")
	if !strings.Contains(shown, "Docs:") || !strings.Contains(shown, "https://emisar.dev/packs/withdocs") {
		t.Errorf("expected the pack's own docs link; got:\n%s", shown)
	}

	hidden := info("nodocs")
	if strings.Contains(hidden, "Docs:") {
		t.Errorf("a pack with no homepage must print no Docs line; got:\n%s", hidden)
	}
}

// A pack description is a folded YAML paragraph — 200+ runes ending in a
// newline — and `pack list` printed it raw into the tabwriter cell: every
// column ballooned to paragraph width and the embedded newline broke the row
// model, so the "table" rendered as alternating prose and blank lines. The
// docs show the bounded single-line shape; now the CLI does too.
func TestListDescriptionBoundsAFoldedParagraph(t *testing.T) {
	folded := "Inspect Linux network bonding / LACP: list bond interfaces, read a bond's full status " +
		"from /proc/net/bonding (mode, LACP actor/partner state, per-slave link status).\nSecond line.\n"
	got := listDescription(folded)
	if strings.ContainsRune(got, '\n') {
		t.Errorf("cell carries a newline: %q", got)
	}
	if want := "Inspect Linux network bonding / LACP: list bond interfac…"; got != want {
		t.Errorf("listDescription = %q, want %q", got, want)
	}

	if got := listDescription("Short and sweet.\n"); got != "Short and sweet." {
		t.Errorf("short description mangled: %q", got)
	}

	// Rune-safe: a multi-byte character at the boundary is dropped whole,
	// never cut into invalid UTF-8.
	long := strings.Repeat("é", 60)
	if got := listDescription(long); !utf8.ValidString(got) {
		t.Errorf("truncation produced invalid UTF-8: %q", got)
	}
}
