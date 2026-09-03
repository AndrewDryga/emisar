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

// A real git repository, because the silent-drift case can only be judged by
// comparing the working tree against the workflow as it stood at the pinned
// commit — which is exactly the comparison nobody was making.
func writeTrustedReleaseRepo(t *testing.T, trustedBody string) (root, sha string) {
	t.Helper()
	root = t.TempDir()
	git := func(args ...string) string {
		t.Helper()
		command := exec.Command("git", args...)
		command.Dir = root
		command.Env = append(os.Environ(),
			"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@example.invalid",
			"GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@example.invalid")
		out, err := command.CombinedOutput()
		if err != nil {
			t.Fatalf("git %s: %v (%s)", strings.Join(args, " "), err, out)
		}
		return strings.TrimSpace(string(out))
	}
	write := func(path, body string) {
		t.Helper()
		full := filepath.Join(root, filepath.FromSlash(path))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	git("init", "--quiet")
	write(".github/workflows/runner-release-trusted.yml", trustedBody)
	write(".github/actions/verify-release-tag/action.yml", "name: verify\nruns:\n  using: composite\n")
	write("tools/cmd/releaseenv/main.go", "package main\n")
	write("tools/internal/releaseenv/releaseenv.go", "package releaseenv\n")
	write("tools/go.mod", "module example.invalid/tools\n\ngo 1.26.6\n")
	write("tools/go.sum", "")
	git("add", "-A")
	git("commit", "--quiet", "-m", "trusted workflow")
	sha = git("rev-parse", "HEAD")

	write(".github/workflows/runner-release.yml",
		"jobs:\n  release:\n    uses: AndrewDryga/emisar/.github/workflows/runner-release-trusted.yml@"+sha+"\n")
	write("infra/github_oidc.tf", "locals {\n  trusted_job_workflow_sha = \""+sha+"\"\n}\n")
	return root, sha
}

func TestCheckTrustedReleasePins(t *testing.T) {
	const trusted = "name: trusted\njobs:\n  publish:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: $/.github/actions/verify-release-tag\n"

	t.Run("agreeing pins pass", func(t *testing.T) {
		root, sha := writeTrustedReleaseRepo(t, trusted)
		var out bytes.Buffer
		app := New(root, strings.NewReader(""), &out, &out)
		if err := app.checkTrustedReleasePins(context.Background()); err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(out.String(), sha[:12]) {
			t.Fatalf("output does not name the verified commit: %q", out.String())
		}
	})

	// The dangerous direction: the workflow changed, every pin still names the
	// commit before the change, and the release would go green having shipped
	// the old file.
	t.Run("an edited trusted workflow with a stale pin fails", func(t *testing.T) {
		root, _ := writeTrustedReleaseRepo(t, trusted)
		path := filepath.Join(root, ".github", "workflows", "runner-release-trusted.yml")
		if err := os.WriteFile(path, []byte(trusted+"    environment: production\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		var out bytes.Buffer
		app := New(root, strings.NewReader(""), &out, &out)
		err := app.checkTrustedReleasePins(context.Background())
		if err == nil || !strings.Contains(err.Error(), "silently run the old workflow") {
			t.Fatalf("stale pin not reported: %v", err)
		}
	})

	t.Run("case-only trusted workflow drift fails", func(t *testing.T) {
		root, _ := writeTrustedReleaseRepo(t, trusted)
		path := filepath.Join(root, ".github", "workflows", "runner-release-trusted.yml")
		if err := os.WriteFile(path, []byte(strings.Replace(trusted, "ubuntu-latest", "Ubuntu-Latest", 1)), 0o600); err != nil {
			t.Fatal(err)
		}
		var out bytes.Buffer
		app := New(root, strings.NewReader(""), &out, &out)
		err := app.checkTrustedReleasePins(context.Background())
		if err == nil || !strings.Contains(err.Error(), "silently run the old workflow") {
			t.Fatalf("case-only workflow drift not reported: %v", err)
		}
	})

	t.Run("a shim pinned away from terraform fails", func(t *testing.T) {
		root, sha := writeTrustedReleaseRepo(t, trusted)
		path := filepath.Join(root, ".github", "workflows", "runner-release.yml")
		body, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		other := strings.Repeat("0", 40)
		if err := os.WriteFile(path, bytes.ReplaceAll(body, []byte(sha), []byte(other)), 0o600); err != nil {
			t.Fatal(err)
		}
		var out bytes.Buffer
		app := New(root, strings.NewReader(""), &out, &out)
		err = app.checkTrustedReleasePins(context.Background())
		if err == nil || !strings.Contains(err.Error(), "would fail OIDC") {
			t.Fatalf("mismatched pin not reported: %v", err)
		}
	})

	t.Run("a tag-workspace composite reference fails", func(t *testing.T) {
		root, _ := writeTrustedReleaseRepo(t, strings.Replace(trusted,
			"uses: $/.github/actions/verify-release-tag",
			"uses: ./.github/actions/verify-release-tag", 1))
		var out bytes.Buffer
		app := New(root, strings.NewReader(""), &out, &out)
		err := app.checkTrustedReleasePins(context.Background())
		if err == nil || !strings.Contains(err.Error(), "tag-selected workspace") {
			t.Fatalf("workspace-relative verifier error = %v", err)
		}
	})

	t.Run("a missing composite reference fails", func(t *testing.T) {
		root, _ := writeTrustedReleaseRepo(t, strings.Replace(trusted,
			"      - uses: $/.github/actions/verify-release-tag\n", "", 1))
		var out bytes.Buffer
		app := New(root, strings.NewReader(""), &out, &out)
		err := app.checkTrustedReleasePins(context.Background())
		if err == nil || !strings.Contains(err.Error(), "exactly once") {
			t.Fatalf("missing verifier error = %v", err)
		}
	})

	// A repo-local composite executes at the pinned commit too, so editing one
	// without re-pinning is the same silent failure one directory over.
	t.Run("an edited composite with a stale pin fails", func(t *testing.T) {
		root, _ := writeTrustedReleaseRepo(t, trusted)
		path := filepath.Join(root, ".github", "actions", "verify-release-tag", "action.yml")
		if err := os.WriteFile(path, []byte("name: verify\nruns:\n  using: composite\n# drift\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		var out bytes.Buffer
		app := New(root, strings.NewReader(""), &out, &out)
		err := app.checkTrustedReleasePins(context.Background())
		if err == nil || !strings.Contains(err.Error(), "silently run the old steps") {
			t.Fatalf("stale composite pin not reported: %v", err)
		}
	})

	t.Run("case-only composite drift fails", func(t *testing.T) {
		root, _ := writeTrustedReleaseRepo(t, trusted)
		path := filepath.Join(root, ".github", "actions", "verify-release-tag", "action.yml")
		if err := os.WriteFile(path, []byte("name: Verify\nruns:\n  using: composite\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		var out bytes.Buffer
		app := New(root, strings.NewReader(""), &out, &out)
		err := app.checkTrustedReleasePins(context.Background())
		if err == nil || !strings.Contains(err.Error(), "silently run the old steps") {
			t.Fatalf("case-only composite drift not reported: %v", err)
		}
	})

	t.Run("an edited verifier source with a stale pin fails", func(t *testing.T) {
		root, _ := writeTrustedReleaseRepo(t, trusted)
		path := filepath.Join(root, "tools", "internal", "releaseenv", "releaseenv.go")
		if err := os.WriteFile(path, []byte("package releaseenv\n\nconst drift = true\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		var out bytes.Buffer
		app := New(root, strings.NewReader(""), &out, &out)
		err := app.checkTrustedReleasePins(context.Background())
		if err == nil || !strings.Contains(err.Error(), "silently run the old steps") {
			t.Fatalf("stale verifier pin not reported: %v", err)
		}
	})

	t.Run("an added verifier source file with a stale pin fails", func(t *testing.T) {
		root, _ := writeTrustedReleaseRepo(t, trusted)
		path := filepath.Join(root, "tools", "internal", "releaseenv", "extra.go")
		if err := os.WriteFile(path, []byte("package releaseenv\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		var out bytes.Buffer
		app := New(root, strings.NewReader(""), &out, &out)
		err := app.checkTrustedReleasePins(context.Background())
		if err == nil || !strings.Contains(err.Error(), "does not exist at the pinned commit") {
			t.Fatalf("added verifier source not reported: %v", err)
		}
	})

	t.Run("a deleted verifier source file with a stale pin fails", func(t *testing.T) {
		root, _ := writeTrustedReleaseRepo(t, trusted)
		path := filepath.Join(root, "tools", "internal", "releaseenv", "releaseenv.go")
		if err := os.Remove(path); err != nil {
			t.Fatal(err)
		}
		var out bytes.Buffer
		app := New(root, strings.NewReader(""), &out, &out)
		err := app.checkTrustedReleasePins(context.Background())
		if err == nil || !strings.Contains(err.Error(), "missing from the working tree") {
			t.Fatalf("deleted verifier source not reported: %v", err)
		}
	})

	// A pin that matches nothing is not proof of anything; passing vacuously is
	// how a check stops being a check.
	t.Run("no pin at all fails", func(t *testing.T) {
		root, _ := writeTrustedReleaseRepo(t, trusted)
		if err := os.Remove(filepath.Join(root, ".github", "workflows", "runner-release.yml")); err != nil {
			t.Fatal(err)
		}
		var out bytes.Buffer
		app := New(root, strings.NewReader(""), &out, &out)
		err := app.checkTrustedReleasePins(context.Background())
		if err == nil || !strings.Contains(err.Error(), "no `uses: …-trusted.yml@<sha>` pin") {
			t.Fatalf("absent pin not reported: %v", err)
		}
	})
}
