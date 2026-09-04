package infraops

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// A commit pin is only as honest as the comment beside it. `# v4.1.0` on a
// commit that is really v3.0.0 reads as a current, patched action while the job
// runs a two-major-old one, and the next reviewer bumping that line copies the
// lie forward — one of fifteen pins in .github/ was wrong exactly that way.
// Only the upstream repository knows which tags a commit carries, so this
// resolution is opt-in and scheduled: the offline gate cannot answer it and
// must not pretend to.
var pinnedActionUse = regexp.MustCompile(
	`(?m)^[ \t]*(?:-[ \t]+)?uses:[ \t]*([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)(?:/[^@\s]+)?@([0-9a-f]{40})[ \t]+#[ \t]*(\S+)[ \t]*$`)

const githubAPI = "https://api.github.com"

// One pin, and every line that spells it the same way, so a wrong comment names
// all the places it has to be fixed.
type actionPin struct {
	repository string
	sha        string
	label      string
	sources    []string
}

func (a *App) checkReleasePinComments(ctx context.Context) error {
	pins, err := collectActionPins(a.Root)
	if err != nil {
		return err
	}
	if len(pins) == 0 {
		return fmt.Errorf(".github holds no `uses: owner/repo@<sha> # <version>` pin to resolve")
	}

	resolver := &tagResolver{
		client:   &http.Client{Timeout: 30 * time.Second},
		endpoint: a.GitHubAPI,
		token:    os.Getenv("GITHUB_TOKEN"),
		refs:     map[string][]tagRef{},
		commits:  map[string]string{},
	}

	var wrong []string
	for _, pin := range pins {
		tags, err := resolver.tags(ctx, pin.repository)
		if err != nil {
			return err
		}
		match, actual, err := matchPinLabel(ctx, resolver, pin, tags)
		if err != nil {
			return err
		}
		if match != "" {
			fmt.Fprintf(a.Out, "  %s@%s # %s is %s\n", pin.repository, pin.sha[:12], pin.label, match)
			continue
		}
		detail := "carries no tag upstream"
		if len(actual) > 0 {
			detail = "is " + strings.Join(actual, ", ")
		}
		wrong = append(wrong, fmt.Sprintf("%s: %s@%s is commented # %s, but that commit %s",
			strings.Join(pin.sources, ", "), pin.repository, pin.sha[:12], pin.label, detail))
	}
	if len(wrong) > 0 {
		return fmt.Errorf("%d pinned action comment(s) name a version their commit is not:\n  %s",
			len(wrong), strings.Join(wrong, "\n  "))
	}
	fmt.Fprintf(a.Out, "verified: %d pinned action comment(s) resolve to a matching upstream tag\n", len(pins))
	return nil
}

// A pin without a version comment is left alone: the release shims pin a
// first-party reusable workflow by commit with nothing to compare against, and
// checkTrustedReleasePins already owns that pin.
func collectActionPins(root string) ([]actionPin, error) {
	index := map[string]int{}
	var pins []actionPin

	walked := filepath.Join(root, ".github")
	err := filepath.WalkDir(walked, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() || (filepath.Ext(path) != ".yml" && filepath.Ext(path) != ".yaml") {
			return nil
		}
		body, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		for _, match := range pinnedActionUse.FindAllSubmatchIndex(body, -1) {
			field := func(group int) string { return string(body[match[2*group]:match[2*group+1]]) }
			pin := actionPin{repository: field(1) + "/" + field(2), sha: field(3), label: field(4)}
			source := fmt.Sprintf("%s:%d", filepath.ToSlash(relative), 1+bytes.Count(body[:match[0]], []byte("\n")))
			key := pin.repository + "@" + pin.sha + "#" + pin.label
			if at, seen := index[key]; seen {
				pins[at].sources = append(pins[at].sources, source)
				continue
			}
			pin.sources = []string{source}
			index[key] = len(pins)
			pins = append(pins, pin)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Slice(pins, func(i, j int) bool { return pins[i].sources[0] < pins[j].sources[0] })
	return pins, nil
}

// Resolving every tag costs a request per annotated tag, so try the ones the
// label could name first and settle the common case in one or two. Only a pin
// that fails pays for the full sweep — and it has to, because naming what the
// commit actually IS is the difference between "fix the comment" and "the pin
// moved to a version nobody reviewed".
func matchPinLabel(ctx context.Context, resolver *tagResolver, pin actionPin, tags []tagRef) (string, []string, error) {
	for _, tag := range tags {
		if !labelCovers(pin.label, tag.name) {
			continue
		}
		commit, err := resolver.commit(ctx, pin.repository, tag)
		if err != nil {
			return "", nil, err
		}
		if commit == pin.sha {
			return tag.name, nil, nil
		}
	}
	var actual []string
	for _, tag := range tags {
		commit, err := resolver.commit(ctx, pin.repository, tag)
		if err != nil {
			return "", nil, err
		}
		if commit == pin.sha {
			actual = append(actual, tag.name)
		}
	}
	sort.Strings(actual)
	return "", actual, nil
}

// A comment may name the floating major an action publishes (`# v4`), which any
// v4.x.y release satisfies; a more specific label has to be the tag itself.
// Extending only at a dot keeps `v4` from being satisfied by `v40.0.0`.
func labelCovers(label, tag string) bool {
	return tag == label || strings.HasPrefix(tag, label+".")
}

type tagRef struct {
	name       string
	objectKind string
	objectSHA  string
}

type tagResolver struct {
	client   *http.Client
	endpoint string
	token    string
	refs     map[string][]tagRef
	commits  map[string]string
}

func (r *tagResolver) tags(ctx context.Context, repository string) ([]tagRef, error) {
	if cached, ok := r.refs[repository]; ok {
		return cached, nil
	}
	const perPage = 100
	refs := []tagRef{}
	for page := 1; ; page++ {
		var payload []struct {
			Ref    string `json:"ref"`
			Object struct {
				Type string `json:"type"`
				SHA  string `json:"sha"`
			} `json:"object"`
		}
		url := fmt.Sprintf("%s/repos/%s/git/refs/tags?per_page=%d&page=%d", r.endpoint, repository, perPage, page)
		if err := r.get(ctx, url, &payload); err != nil {
			return nil, err
		}
		for _, entry := range payload {
			refs = append(refs, tagRef{
				name:       strings.TrimPrefix(entry.Ref, "refs/tags/"),
				objectKind: entry.Object.Type,
				objectSHA:  entry.Object.SHA,
			})
		}
		// Stopping on a short page keeps a repository that grows past 100 tags
		// from silently reporting every pin as untagged.
		if len(payload) < perPage {
			return r.cache(repository, refs), nil
		}
	}
}

func (r *tagResolver) cache(repository string, refs []tagRef) []tagRef {
	r.refs[repository] = refs
	return refs
}

// A floating major is published as an annotated tag, whose ref names the tag
// object rather than the commit the workflow will run.
func (r *tagResolver) commit(ctx context.Context, repository string, ref tagRef) (string, error) {
	if ref.objectKind == "commit" {
		return ref.objectSHA, nil
	}
	key := repository + " " + ref.objectSHA
	if cached, ok := r.commits[key]; ok {
		return cached, nil
	}
	var payload struct {
		Object struct {
			Type string `json:"type"`
			SHA  string `json:"sha"`
		} `json:"object"`
	}
	if err := r.get(ctx, fmt.Sprintf("%s/repos/%s/git/tags/%s", r.endpoint, repository, ref.objectSHA), &payload); err != nil {
		return "", err
	}
	if payload.Object.Type != "commit" {
		return "", fmt.Errorf("%s tag %s dereferences to a %s, not a commit", repository, ref.name, payload.Object.Type)
	}
	r.commits[key] = payload.Object.SHA
	return payload.Object.SHA, nil
}

func (r *tagResolver) get(ctx context.Context, url string, into any) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	if r.token != "" {
		request.Header.Set("Authorization", "Bearer "+r.token)
	}
	response, err := r.client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 8<<20))
	if err != nil {
		return err
	}
	if response.StatusCode != http.StatusOK {
		// An anonymous caller gets 60 requests an hour, which this check can
		// exhaust; say so instead of reporting it as a pin problem.
		if response.StatusCode == http.StatusForbidden || response.StatusCode == http.StatusTooManyRequests {
			return fmt.Errorf("GET %s: %s (set GITHUB_TOKEN to raise the GitHub API rate limit)", url, response.Status)
		}
		return fmt.Errorf("GET %s: %s", url, response.Status)
	}
	return json.Unmarshal(body, into)
}
