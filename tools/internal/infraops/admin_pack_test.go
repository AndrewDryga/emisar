package infraops

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func writeAdminAction(t *testing.T, pack, name, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(pack, "actions"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(pack, "actions", name), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

func readActions(t *testing.T, pack string) []adminAction {
	t.Helper()
	actions, err := readAdminActions(pack)
	if err != nil {
		t.Fatal(err)
	}
	return actions
}

// The real pack has two actions sitting exactly on the ceiling, so the check
// must accept five entries and refuse six.
func TestAdminActionArgvCeiling(t *testing.T) {
	pack := t.TempDir()
	writeAdminAction(t, pack, "member_set_role.yaml", `execution:
  script: {path: scripts/callback.sh, interpreter: /bin/sh}
  argv: ["emisar.admin.member.set_role", "account={{ args.account }}", "member={{ args.member }}", "role={{ args.role }}", "runner_access={{ args.runner_access? }}"]
`)
	writeAdminAction(t, pack, "runtime_status.yaml", `execution:
  script: {path: scripts/other.sh, interpreter: /bin/sh}
  argv: ["a", "b", "c", "d", "e", "f"]
`)
	if err := checkAdminActionArgvCeiling(readActions(t, pack)); err != nil {
		t.Fatalf("ceiling rejected a compliant pack: %v", err)
	}

	writeAdminAction(t, pack, "member_set_role.yaml", `execution:
  script: {path: scripts/callback.sh, interpreter: /bin/sh}
  argv: ["emisar.admin.member.set_role", "account={{ args.account }}", "member={{ args.member }}", "role={{ args.role }}", "runner_access={{ args.runner_access? }}", "note={{ args.note }}"]
`)
	err := checkAdminActionArgvCeiling(readActions(t, pack))
	if err == nil || !strings.Contains(err.Error(), "member_set_role.yaml passes 6 argv entries") {
		t.Fatalf("a sixth argv entry was not reported: %v", err)
	}
}

func TestAdminActionsMustBeDeclared(t *testing.T) {
	pack := t.TempDir()
	writeAdminAction(t, pack, "runtime_status.yaml", "id: emisar.admin.runtime.status\n")
	if err := os.WriteFile(filepath.Join(pack, "pack.yaml"),
		[]byte("actions:\n  - actions/runtime_status.yaml\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := checkAdminActionsDeclared(pack, readActions(t, pack)); err != nil {
		t.Fatalf("a declared action was rejected: %v", err)
	}

	writeAdminAction(t, pack, "account_purge.yaml", "id: emisar.admin.account.purge\n")
	err := checkAdminActionsDeclared(pack, readActions(t, pack))
	if err == nil || !strings.Contains(err.Error(), "actions/account_purge.yaml is not declared in pack.yaml") {
		t.Fatalf("an undeclared action file was not reported: %v", err)
	}
}

// repositoryRoot is where the private pack and the runner module both live.
func repositoryRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	return root
}

// adminRunnerBinary builds the runner from this tree. Building it is the point:
// these fixtures have to be held to the loader an admin-runner actually boots
// with, not to a second copy of its rules kept here.
func adminRunnerBinary(t *testing.T, root string) string {
	t.Helper()
	binary := filepath.Join(t.TempDir(), "emisar")
	build := exec.Command("go", "build", "-trimpath", "-o", binary, ".")
	build.Dir = filepath.Join(root, "runner")
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("building the runner: %v\n%s", err, output)
	}
	return binary
}

// corruptAdminPack copies the real pack and replaces one literal in one action,
// so every fixture below differs from the shipped pack by exactly one field.
func corruptAdminPack(t *testing.T, root, action, from, to string) string {
	t.Helper()
	pack := filepath.Join(t.TempDir(), "emisar-admin")
	if err := os.CopyFS(pack, os.DirFS(filepath.Join(root, "infra", "packs", "emisar-admin"))); err != nil {
		t.Fatal(err)
	}
	if action == "" {
		return pack
	}
	path := filepath.Join(pack, "actions", action)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), from) {
		t.Fatalf("%s no longer contains %q to corrupt", action, from)
	}
	if err := os.WriteFile(path, []byte(strings.Replace(string(data), from, to, 1)), 0o600); err != nil {
		t.Fatal(err)
	}
	return pack
}

// The gap this closes: every corruption below passed `./run gate infra` and
// `./run gate packs` and first failed at `pack list` during admin-runner boot.
func TestAdminPackSpecValidation(t *testing.T) {
	root := repositoryRoot(t)
	binary := adminRunnerBinary(t, root)

	var out bytes.Buffer
	app := New(root, nil, &out, &out)
	if err := app.validateAdminPackWith(context.Background(), binary,
		filepath.Join(root, "infra", "packs", "emisar-admin")); err != nil {
		t.Fatalf("the shipped private admin pack does not validate: %v\n%s", err, out.String())
	}
	if !strings.Contains(out.String(), "pack emisar-admin OK") {
		t.Fatalf("validation reported nothing: %q", out.String())
	}

	for _, test := range []struct {
		name   string
		action string
		from   string
		to     string
		want   []string
	}{
		{
			name:   "duration",
			action: "account_erase.yaml",
			from:   "timeout:",
			to:     "timeout: 2minutes #",
			want:   []string{"account_erase.yaml", `invalid duration "2minutes"`},
		},
		{
			// The id is emisar.admin.support.set_slack_channel, so only the
			// file the loader's error is annotated with leads an author here.
			name:   "risk",
			action: "support_set_slack_channel.yaml",
			from:   "risk: high",
			to:     "risk: catastrophic",
			want:   []string{"actions/support_set_slack_channel.yaml", `invalid risk "catastrophic"`},
		},
		{
			name:   "argv template",
			action: "account_show.yaml",
			from:   "account={{ args.account }}",
			to:     "account={{ args.acount }}",
			want:   []string{"actions/account_show.yaml", "unknown variable args.acount"},
		},
		{
			name:   "arg validation",
			action: "account_show.yaml",
			from:   "validation: {max_length: 128}",
			to:     `validation: {pattern: "([a-z"}`,
			want:   []string{"actions/account_show.yaml", `invalid validation.pattern "([a-z"`},
		},
		{
			name:   "output parser",
			action: "runtime_status.yaml",
			from:   "parser: json",
			to:     "parser: yaml",
			want:   []string{"actions/runtime_status.yaml", `invalid parser "yaml"`},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			pack := corruptAdminPack(t, root, test.action, test.from, test.to)
			var out bytes.Buffer
			app := New(root, nil, &out, &out)
			err := app.validateAdminPackWith(context.Background(), binary, pack)
			if err == nil {
				t.Fatalf("a corrupted %s passed validation: %s", test.name, out.String())
			}
			for _, want := range test.want {
				if !strings.Contains(err.Error(), want) {
					t.Fatalf("error does not name %q: %v", want, err)
				}
			}
		})
	}

	// The loader only reads what pack.yaml declares, so this one has to be
	// caught here or not at all.
	t.Run("undeclared action", func(t *testing.T) {
		pack := corruptAdminPack(t, root, "", "", "")
		writeAdminAction(t, pack, "account_purge.yaml", "id: emisar.admin.account.purge\n")
		var out bytes.Buffer
		app := New(root, nil, &out, &out)
		err := app.validateAdminPackWith(context.Background(), binary, pack)
		if err == nil || !strings.Contains(err.Error(), "actions/account_purge.yaml is not declared in pack.yaml") {
			t.Fatalf("an undeclared action file was not reported: %v", err)
		}
	})
}
