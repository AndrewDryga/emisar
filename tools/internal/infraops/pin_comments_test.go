package infraops

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The upstream shapes this fixture reproduces were read from the live API this
// session: actions/attest-sbom publishes v3.0.0 and v4.1.0 as lightweight tags
// whose ref names the commit, and v3/v4 as ANNOTATED tags whose ref names a tag
// object that has to be dereferenced to reach the commit. Getting that backwards
// is how a floating-major comment looks wrong when it is right.
const (
	sbomV3Commit = "4651f806c01d8637787e274ac3bdf724ef169f34"
	sbomV4Commit = "c604332985a26aa8cf1bdc465b92731239ec6b9e"
	sbomV4Tag    = "36590ecaf038d6630c74f2da259095627d52ac11"
	checkoutV7   = "3d3c42e5aac5ba805825da76410c181273ba90b1"
)

type tagFixture struct {
	name string
	kind string // "commit" for a lightweight tag, "tag" for an annotated one
	sha  string // the object the ref names
}

// A GitHub tag API standing in for the two endpoints this check reads, so the
// dereference hop is exercised rather than assumed.
func githubFixture(t *testing.T, repositories map[string][]tagFixture, annotated map[string]string) *httptest.Server {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		write := func(payload any) {
			w.Header().Set("Content-Type", "application/json")
			if err := json.NewEncoder(w).Encode(payload); err != nil {
				t.Errorf("encoding fixture response: %v", err)
			}
		}
		path := strings.TrimPrefix(r.URL.Path, "/repos/")
		if repository, sha, ok := strings.Cut(path, "/git/tags/"); ok {
			commit, known := annotated[repository+" "+sha]
			if !known {
				http.Error(w, "no such tag object", http.StatusNotFound)
				return
			}
			write(map[string]any{"object": map[string]string{"type": "commit", "sha": commit}})
			return
		}
		repository, ok := strings.CutSuffix(path, "/git/refs/tags")
		if !ok {
			http.Error(w, "unexpected path "+r.URL.Path, http.StatusNotFound)
			return
		}
		tags, known := repositories[repository]
		if !known {
			http.Error(w, "no such repository", http.StatusNotFound)
			return
		}
		if r.URL.Query().Get("page") != "1" {
			write([]any{})
			return
		}
		refs := make([]any, 0, len(tags))
		for _, tag := range tags {
			refs = append(refs, map[string]any{
				"ref":    "refs/tags/" + tag.name,
				"object": map[string]string{"type": tag.kind, "sha": tag.sha},
			})
		}
		write(refs)
	}))
	t.Cleanup(server.Close)
	return server
}

func writeWorkflow(t *testing.T, root, name, body string) {
	t.Helper()
	path := filepath.Join(root, ".github", "workflows", name)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestCheckReleasePinComments(t *testing.T) {
	repositories := map[string][]tagFixture{
		"actions/attest-sbom": {
			{name: "predicate@1.0.0", kind: "tag", sha: "13f883f6ec27fd4cee8c18b17624946983dc0e4b"},
			{name: "v3.0.0", kind: "commit", sha: sbomV3Commit},
			{name: "v4", kind: "tag", sha: sbomV4Tag},
			{name: "v4.1.0", kind: "commit", sha: sbomV4Commit},
			{name: "v40.0.0", kind: "commit", sha: strings.Repeat("a", 40)},
		},
		"actions/checkout": {
			{name: "v7", kind: "commit", sha: checkoutV7},
			{name: "v7.0.1", kind: "commit", sha: checkoutV7},
		},
	}
	annotated := map[string]string{
		"actions/attest-sbom " + sbomV4Tag:                             sbomV4Commit,
		"actions/attest-sbom 13f883f6ec27fd4cee8c18b17624946983dc0e4b": strings.Repeat("c", 40),
	}

	for _, test := range []struct {
		name     string
		workflow string
		want     string
	}{
		{
			name: "an exact label on its own commit passes",
			workflow: "jobs:\n  publish:\n    steps:\n" +
				"      - uses: actions/attest-sbom@" + sbomV3Commit + " # v3.0.0\n",
		},
		{
			// The floating major has advanced past the release it was pinned at,
			// so `# v4` stays true while `# v4.1.0` would go stale on every bump.
			name: "a floating major label is satisfied by the release it points at",
			workflow: "jobs:\n  publish:\n    steps:\n" +
				"      - uses: actions/attest-sbom@" + sbomV4Commit + " # v4\n",
		},
		{
			// The real defect: the comment named a version two majors newer than
			// the commit, and the pin read as current.
			name: "a label naming a different version fails",
			workflow: "jobs:\n  publish:\n    steps:\n" +
				"      - uses: actions/attest-sbom@" + sbomV3Commit + " # v4.1.0\n",
			want: "is commented # v4.1.0, but that commit is v3.0.0",
		},
		{
			name: "a major label is not satisfied by a longer number",
			workflow: "jobs:\n  publish:\n    steps:\n" +
				"      - uses: actions/attest-sbom@" + strings.Repeat("a", 40) + " # v4\n",
			want: "is commented # v4, but that commit is v40.0.0",
		},
		{
			name: "a commit no tag names fails",
			workflow: "jobs:\n  publish:\n    steps:\n" +
				"      - uses: actions/attest-sbom@" + strings.Repeat("b", 40) + " # v4.1.0\n",
			want: "carries no tag upstream",
		},
		{
			// actions/cache/restore@<sha> pins a subdirectory action; the tags
			// live on the repository, not the path.
			name: "a subdirectory action resolves against its repository",
			workflow: "jobs:\n  publish:\n    steps:\n" +
				"      - uses: actions/checkout/some-action@" + checkoutV7 + " # v7.0.1\n",
		},
		{
			// The release shims pin a first-party reusable workflow by commit with
			// no comment to compare; checkTrustedReleasePins owns that one.
			name: "a pin without a comment is left to the offline check",
			workflow: "jobs:\n  release:\n" +
				"    uses: AndrewDryga/emisar/.github/workflows/runner-release-trusted.yml@" + checkoutV7 + "\n" +
				"  publish:\n    steps:\n      - uses: actions/checkout@" + checkoutV7 + " # v7\n",
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			root := t.TempDir()
			writeWorkflow(t, root, "ci.yml", test.workflow)
			server := githubFixture(t, repositories, annotated)

			var out bytes.Buffer
			app := New(root, strings.NewReader(""), &out, &out)
			app.GitHubAPI = server.URL
			err := app.checkReleasePinComments(context.Background())
			if test.want == "" {
				if err != nil {
					t.Fatalf("unexpected error: %v\n%s", err, out.String())
				}
				if !strings.Contains(out.String(), "verified: 1 pinned action comment") {
					t.Fatalf("output does not report one verified pin: %q", out.String())
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want %q", err, test.want)
			}
		})
	}

	// A pin repeated across files has to name every line, or fixing it means
	// running the check again for each remaining copy.
	t.Run("a wrong comment names every line that spells it", func(t *testing.T) {
		root := t.TempDir()
		body := "jobs:\n  publish:\n    steps:\n      - uses: actions/attest-sbom@" + sbomV3Commit + " # v4.1.0\n"
		writeWorkflow(t, root, "ci.yml", body)
		writeWorkflow(t, root, "cd.yml", "\n\n"+body)
		server := githubFixture(t, repositories, annotated)

		var out bytes.Buffer
		app := New(root, strings.NewReader(""), &out, &out)
		app.GitHubAPI = server.URL
		err := app.checkReleasePinComments(context.Background())
		if err == nil {
			t.Fatal("duplicated wrong pin not reported")
		}
		for _, want := range []string{".github/workflows/cd.yml:6", ".github/workflows/ci.yml:4", "1 pinned action comment(s)"} {
			if !strings.Contains(err.Error(), want) {
				t.Fatalf("error %q does not contain %q", err.Error(), want)
			}
		}
	})

	// A check that passes because it matched nothing is not a check.
	t.Run("no pin at all fails", func(t *testing.T) {
		root := t.TempDir()
		writeWorkflow(t, root, "ci.yml", "jobs:\n  publish:\n    steps:\n      - run: ./run gate tooling\n")
		server := githubFixture(t, repositories, annotated)

		var out bytes.Buffer
		app := New(root, strings.NewReader(""), &out, &out)
		app.GitHubAPI = server.URL
		err := app.checkReleasePinComments(context.Background())
		if err == nil || !strings.Contains(err.Error(), "no `uses: owner/repo@<sha> # <version>` pin") {
			t.Fatalf("absent pin not reported: %v", err)
		}
	})

	t.Run("an exhausted rate limit is not reported as a bad pin", func(t *testing.T) {
		root := t.TempDir()
		writeWorkflow(t, root, "ci.yml",
			"jobs:\n  publish:\n    steps:\n      - uses: actions/checkout@"+checkoutV7+" # v7\n")
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			http.Error(w, "API rate limit exceeded", http.StatusForbidden)
		}))
		t.Cleanup(server.Close)

		var out bytes.Buffer
		app := New(root, strings.NewReader(""), &out, &out)
		app.GitHubAPI = server.URL
		err := app.checkReleasePinComments(context.Background())
		if err == nil || !strings.Contains(err.Error(), "set GITHUB_TOKEN") {
			t.Fatalf("rate limit error = %v", err)
		}
	})
}

func TestLabelCovers(t *testing.T) {
	for _, test := range []struct {
		label, tag string
		want       bool
	}{
		{label: "v7.0.0", tag: "v7.0.0", want: true},
		{label: "v7.0.0", tag: "v7.0.1"},
		{label: "v7.0.0", tag: "v7.0.0-beta.1"},
		{label: "v4", tag: "v4", want: true},
		{label: "v4", tag: "v4.1.1", want: true},
		{label: "v4", tag: "v40.0.0"},
		{label: "v4", tag: "v4x"},
		{label: "v1.24", tag: "v1.24.1", want: true},
		{label: "v8", tag: "v7.9.9"},
	} {
		t.Run(test.label+"/"+test.tag, func(t *testing.T) {
			if got := labelCovers(test.label, test.tag); got != test.want {
				t.Fatalf("labelCovers(%q, %q) = %v, want %v", test.label, test.tag, got, test.want)
			}
		})
	}
}
