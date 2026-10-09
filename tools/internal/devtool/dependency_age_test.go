package devtool

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestReviewGatePropagatesResolvedDependencyBase(t *testing.T) {
	for _, tc := range []struct {
		name, ref string
		fail      bool
	}{
		{name: "session parent", ref: "refs/coop/session-parent"},
		{name: "explicit review base", ref: "refs/coop/explicit-base"},
		{name: "dependency failure", ref: "refs/coop/session-parent", fail: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			app, capture := dependencyReviewFixture(t)
			gitIn(t, app.Root, "update-ref", tc.ref, "HEAD")
			cmd := exec.Command("git", "rev-parse", "HEAD")
			cmd.Dir = app.Root
			base, err := cmd.Output()
			if err != nil {
				t.Fatal(err)
			}
			t.Setenv("COOP_REVIEW_BASE", "")
			if tc.ref != "refs/coop/session-parent" {
				t.Setenv("COOP_REVIEW_BASE", tc.ref)
			}
			t.Setenv("DEP_AGE_BASE_REF", "missing-origin-main")
			t.Setenv("TEST_DEP_EXIT", "0")
			if tc.fail {
				t.Setenv("TEST_DEP_EXIT", "2")
			}
			err = app.Run(t.Context(), []string{"gate", "review"})
			if tc.fail {
				if err == nil || ExitCode(err) != 2 {
					t.Fatalf("dependency failure not propagated: %v", err)
				}
			} else if err != nil {
				t.Fatal(err)
			}
			got, err := os.ReadFile(capture)
			if err != nil {
				t.Fatal(err)
			}
			want := "run\n./cmd/depgate\ncheck\n--base\n" + string(base)
			if string(got) != want {
				t.Fatalf("dependency arguments = %q, want %q", got, want)
			}
			if os.Getenv("DEP_AGE_BASE_REF") != "missing-origin-main" {
				t.Fatal("review mutated the ambient baseline")
			}
			// The review copy must not change later ordinary invocations.
			t.Setenv("TEST_DEP_EXIT", "0")
			if err := app.Run(t.Context(), []string{"check", "deps", "--base", "ordinary-base"}); err != nil {
				t.Fatal(err)
			}
			got, err = os.ReadFile(capture)
			if err != nil {
				t.Fatal(err)
			}
			if string(got) != "run\n./cmd/depgate\ncheck\n--base\nordinary-base\n" {
				t.Fatalf("review base leaked: %q", got)
			}
		})
	}
}

func TestReviewGateRejectsMissingBase(t *testing.T) {
	app, capture := dependencyReviewFixture(t)
	t.Setenv("COOP_REVIEW_BASE", "missing-review-base")
	if err := app.Run(t.Context(), []string{"gate", "review"}); err == nil || !strings.Contains(err.Error(), "review base is unavailable") {
		t.Fatalf("missing review base = %v", err)
	}
	if _, err := os.Stat(capture); !os.IsNotExist(err) {
		t.Fatalf("dependency check ran without a review base: %v", err)
	}
}

// The real review entry point selects and runs the canonical tooling gate.
// External checkers are no-ops except depgate, whose argv/status is observed;
// the repository-owned configuration checks still run on current fixtures.
func dependencyReviewFixture(t *testing.T) (*App, string) {
	t.Helper()
	app := testApp(t)
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	files := []string{
		".tool-versions", "docker-compose.yml", "portal/config/config.exs", "portal/Dockerfile",
		"dev/compose.yml", "dev/review-compose.yml", ".github/workflows/ci.yml", ".github/dependabot.yml",
		".agent/Dockerfile", "dev/test-packs/gcloud/Dockerfile", "run",
		"packs/gcp-load-balancing/pack.yaml", "packs/gcp-load-balancing/test/cases.yaml", "packs/gcp-load-balancing/test/compose.yaml",
	}
	for _, file := range files {
		data, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(file)))
		if err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(app.Root, filepath.FromSlash(file))
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, data, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	for _, dir := range []string{"tools", "packs", "bin"} {
		if err := os.MkdirAll(filepath.Join(app.Root, dir), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	writeStaticcheckFixture(t, app.Root)
	gitIn(t, app.Root, "init", "-q")
	gitIn(t, app.Root, "config", "user.name", "Test")
	gitIn(t, app.Root, "config", "user.email", "test@example.com")
	gitIn(t, app.Root, "config", "commit.gpgsign", "false")
	gitIn(t, app.Root, "add", ".")
	gitIn(t, app.Root, "commit", "-q", "-m", "review fixture")
	capture := filepath.Join(t.TempDir(), "dep-arguments")
	bin := filepath.Join(app.Root, "bin")
	script := "#!/bin/sh\nif [ \"$1 $2 $3\" = 'run ./cmd/depgate check' ]; then\n  printf '%s\\n' \"$@\" > \"$TEST_DEP_ARGS\"\n  exit \"$TEST_DEP_EXIT\"\nfi\n"
	script += fakeStaticcheckGo
	if err := os.WriteFile(filepath.Join(bin, "go"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, checker := range []string{"shellcheck", "bash"} {
		if err := os.WriteFile(filepath.Join(bin, checker), []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("TEST_DEP_ARGS", capture)
	t.Setenv("TEST_DEP_EXIT", "0")
	t.Setenv("COMMAND_LOG", filepath.Join(t.TempDir(), "checker-commands"))
	return app, capture
}
