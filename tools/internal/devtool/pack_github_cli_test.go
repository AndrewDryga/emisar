package devtool

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// The provider is not arranged with production credentials. This fixture only
// proves the shipped POSIX script's argv, projection and error/visibility
// contract. Current native gh parsing is separately checked during qualification.
const githubCLIStub = `#!/bin/sh
set -eu
printf '%s\000' "$@" >>"$CALL_LOG"
printf '\000' >>"$CALL_LOG"
case "$1 $2" in
  'search prs') phase=search ;;
  'pr checks') phase=checks ;;
  'pr view')
    case "$7" in headRefOid) phase=head ;; *) phase=details ;; esac ;;
  'api --method')
    [ "$3" = GET ] || exit 98
    case "$4" in
      */status\?*) phase=statuses ;;
      */actions/runs\?*) phase=runs ;;
      */attempts/*/jobs\?*) phase=jobs ;;
      *) exit 97 ;;
    esac ;;
  *) exit 96 ;;
esac
if [ "${FAIL_AT:-}" = "$phase" ]; then
  printf '%s\n' 'provider failure with fixture-canary-do-not-replay' >&2
  exit "${FAIL_CODE:-7}"
fi
if [ "$phase" = checks ] && [ -f "$FIXTURES/checks-error" ]; then
  cat "$FIXTURES/checks-error" >&2
  exit "${CHECKS_CODE:-1}"
fi
if [ "$phase" = jobs ]; then
  route=${4%%/attempts/*}
  id=${route##*/}
  jq --argjson id "$id" '.jobs |= map(.run_id = $id)' "$FIXTURES/jobs"
else
  cat "$FIXTURES/$phase"
fi
`

const githubHead = "0123456789abcdef0123456789abcdef01234567"
const githubPermission = "GraphQL: Resource not accessible by personal access token (node.commits.nodes.0.commit.statusCheckRollup.contexts.nodes.0)\n"

func githubFixtures() map[string]string {
	return map[string]string{
		"details":  fmt.Sprintf(`{"number":7,"title":"A PR","body":"Keep the full body","state":"OPEN","author":{"login":"dev","unexpected_secret":"fixture-canary-do-not-replay"},"createdAt":"2026-10-10T00:00:00Z","mergedAt":null,"reviewDecision":"APPROVED","headRefOid":%q,"headRefName":"topic","unexpected_secret":"fixture-canary-do-not-replay"}`, githubHead),
		"head":     fmt.Sprintf(`{"headRefOid":%q}`, githubHead),
		"checks":   `[{"name":"build","state":"SUCCESS","bucket":"pass","workflow":"CI","link":"https://github.com/owner/repo/actions/runs/101","startedAt":"","completedAt":"","description":"","event":"pull_request","unexpected_secret":"fixture-canary-do-not-replay"},{"name":"test","state":"FAILURE","bucket":"fail","workflow":"CI","link":"","startedAt":"","completedAt":"","description":"A test failed","event":"pull_request"},{"name":"review","state":"PENDING","bucket":"pending","workflow":"","link":"","startedAt":"","completedAt":"","description":"","event":""}]`,
		"statuses": fmt.Sprintf(`{"sha":%q,"state":"failure","total_count":1,"statuses":[{"context":"external-ci","state":"failure","description":"Not green","target_url":"https://ci.example/run","unexpected_secret":"fixture-canary-do-not-replay"}]}`, githubHead),
		"runs":     fmt.Sprintf(`{"total_count":1,"workflow_runs":[{"id":101,"run_attempt":2,"head_sha":%q,"name":"CI","status":"completed","conclusion":"failure","html_url":"https://github.com/owner/repo/actions/runs/101","unexpected_secret":"fixture-canary-do-not-replay"}]}`, githubHead),
		"jobs":     fmt.Sprintf(`{"total_count":1,"jobs":[{"id":201,"run_id":101,"run_attempt":2,"head_sha":%q,"name":"test","status":"completed","conclusion":"failure","unexpected_secret":"fixture-canary-do-not-replay"}]}`, githubHead),
		"search":   `[]`,
	}
}

func runGitHubScript(t *testing.T, script string, fixtures map[string]string, env []string, argv ...string) (packScriptRun, [][]string) {
	t.Helper()
	dir := t.TempDir()
	bin := filepath.Join(dir, "bin")
	if err := os.Mkdir(bin, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bin, "gh"), []byte(githubCLIStub), 0o700); err != nil {
		t.Fatal(err)
	}
	// Linux's common 128 KiB per-argument ceiling is otherwise invisible on
	// macOS. This guard makes every large-result row fail if JSON travels in
	// argv, while the real jq still parses and projects file-backed inputs.
	jqPath, err := exec.LookPath("jq")
	if err != nil {
		t.Fatal(err)
	}
	jqGuard := "#!/bin/sh\nset -eu\nexport LC_ALL=C\nfor arg do [ \"${#arg}\" -le 131071 ] || { printf '%s\\n' 'fixture per-argument ceiling' >&2; exit 126; }; done\nexec \"$REAL_JQ\" \"$@\"\n"
	if err := os.WriteFile(filepath.Join(bin, "jq"), []byte(jqGuard), 0o700); err != nil {
		t.Fatal(err)
	}
	for name, body := range fixtures {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	log := filepath.Join(dir, "calls")
	cmd := exec.Command("/bin/sh", append([]string{filepath.Join("..", "..", "..", "packs", "github-cli", "scripts", script+".sh")}, argv...)...)
	cmd.Env = append(env, "PATH="+bin+string(os.PathListSeparator)+os.Getenv("PATH"), "REAL_JQ="+jqPath, "FIXTURES="+dir, "CALL_LOG="+log)
	var out, diagnostic bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &diagnostic
	run := packScriptRun{}
	err = cmd.Run()
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		run.exit = exit.ExitCode()
	} else if err != nil {
		t.Fatal(err)
	}
	run.stdout, run.stderr = out.String(), diagnostic.String()
	raw, err := os.ReadFile(log)
	if os.IsNotExist(err) {
		return run, nil
	}
	if err != nil {
		t.Fatal(err)
	}
	var calls [][]string
	for _, call := range strings.Split(strings.TrimSuffix(string(raw), "\x00\x00"), "\x00\x00") {
		calls = append(calls, strings.Split(call, "\x00"))
	}
	return run, calls
}

func githubJSON(t *testing.T, run packScriptRun) map[string]any {
	t.Helper()
	if run.exit != 0 || run.stderr != "" {
		t.Fatalf("query failed: %#v", run)
	}
	if strings.Contains(run.stdout, "fixture-canary-do-not-replay") {
		t.Fatal("unrequested provider fields escaped projection")
	}
	var result map[string]any
	if err := json.Unmarshal([]byte(run.stdout), &result); err != nil {
		t.Fatalf("JSON result: %v: %s", err, run.stdout)
	}
	return result
}

func TestGitHubSearchLiteralTermsAndEmptyGuard(t *testing.T) {
	terms := []string{"repo:owner/repo", "state:open", "-label:wontfix", "label:help wanted", "--web", "$(touch injected)"}
	run, calls := runGitHubScript(t, "search_prs", githubFixtures(), nil, append([]string{"37"}, terms...)...)
	want := append([]string{"search", "prs", "--limit", "37", "--json", "number,title,repository,author,state,createdAt,updatedAt", "--"}, terms...)
	if run.exit != 0 || !reflect.DeepEqual(calls, [][]string{want}) {
		t.Fatalf("literal operands: %#v, calls %#v", run, calls)
	}
	for _, query := range [][]string{nil, {""}, {" \t\n"}, {"state:open", ""}} {
		run, calls := runGitHubScript(t, "search_prs", githubFixtures(), nil, append([]string{"100"}, query...)...)
		if run.exit != 2 || run.stdout != "" || len(calls) != 0 {
			t.Fatalf("empty search dispatched: %#v, %#v", run, calls)
		}
	}
	run, _ = runGitHubScript(t, "search_prs", githubFixtures(), []string{"FAIL_AT=search", "FAIL_CODE=8"}, "1", "state:open")
	if run.exit != 8 {
		t.Fatalf("search source failure swallowed: %#v", run)
	}
}

func TestGitHubPRChecksPrimaryAndDetails(t *testing.T) {
	for _, mode := range []string{"checks", "view"} {
		t.Run(mode, func(t *testing.T) {
			run, calls := runGitHubScript(t, "pr_checks", githubFixtures(), nil, mode, "owner/repo", "7")
			result := githubJSON(t, run)
			if mode == "view" {
				if result["body"] != "Keep the full body" || result["reviewDecision"] != "APPROVED" || result["number"] != float64(7) {
					t.Fatalf("PR details lost: %#v", result)
				}
				result = result["statusCheckRollup"].(map[string]any)
			}
			checks := result["checks"].([]any)
			if result["head_sha"] != githubHead || result["source"] != "check_contexts" || len(checks) != 3 || checks[1].(map[string]any)["bucket"] != "fail" || checks[2].(map[string]any)["bucket"] != "pending" {
				t.Fatalf("failed/pending checks are query data: %#v", result)
			}
			if len(calls) != 3 || !reflect.DeepEqual(calls[1], []string{"pr", "checks", "7", "--repo", "owner/repo", "--json", "name,state,bucket,workflow,link,startedAt,completedAt,description,event"}) || calls[2][6] != "headRefOid" {
				t.Fatalf("native JSON/non-watch and head recheck: %#v", calls)
			}
		})
	}
}

func TestGitHubPRChecksPermissionFallbackAndEmpty(t *testing.T) {
	for _, mode := range []string{"checks", "view"} {
		for _, empty := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/empty=%v", mode, empty), func(t *testing.T) {
				fixtures := githubFixtures()
				fixtures["checks-error"] = githubPermission
				if empty {
					fixtures["checks-error"] = "no checks reported on the 'topic' branch\n"
					fixtures["statuses"] = fmt.Sprintf(`{"sha":%q,"state":"pending","total_count":0,"statuses":[]}`, githubHead)
					fixtures["runs"] = `{"total_count":0,"workflow_runs":[]}`
				}
				run, calls := runGitHubScript(t, "pr_checks", fixtures, nil, mode, "owner/repo", "7")
				result := githubJSON(t, run)
				if mode == "view" {
					if result["body"] != "Keep the full body" || result["reviewDecision"] != "APPROVED" {
						t.Fatalf("fallback lost PR details: %#v", result)
					}
					result = result["statusCheckRollup"].(map[string]any)
				}
				if result["source"] != "actions_and_commit_statuses" || result["non_actions_check_runs"] != "not_visible" || result["state"] != nil || result["checks"] != nil {
					t.Fatalf("partial evidence must not be an all-checks verdict: %#v", result)
				}
				if !reflect.DeepEqual(calls[2], []string{"api", "--method", "GET", "repos/owner/repo/commits/" + githubHead + "/status?per_page=100&page=1"}) || !reflect.DeepEqual(calls[3], []string{"api", "--method", "GET", "repos/owner/repo/actions/runs?head_sha=" + githubHead + "&per_page=100&page=1"}) {
					t.Fatalf("immutable-head, bounded GET requests: %#v", calls)
				}
				actions := result["actions"].(map[string]any)
				if empty {
					if len(actions["runs"].([]any)) != 0 || len(calls) != 5 {
						t.Fatalf("genuinely empty response: %#v, %#v", result, calls)
					}
				} else {
					if len(calls) != 6 || calls[4][3] != "repos/owner/repo/actions/runs/101/attempts/2/jobs?per_page=100&page=1" || actions["runs"].([]any)[0].(map[string]any)["conclusion"] != "failure" {
						t.Fatalf("observed-attempt job read / failure data: %#v, %#v", result, calls)
					}
				}
			})
		}
	}
}

func TestGitHubPRChecksNeverHideReadFailures(t *testing.T) {
	for _, phase := range []string{"details", "checks", "statuses", "runs", "jobs", "head"} {
		t.Run(phase, func(t *testing.T) {
			fixtures := githubFixtures()
			fixtures["checks-error"] = githubPermission
			run, _ := runGitHubScript(t, "pr_checks", fixtures, []string{"FAIL_AT=" + phase, "FAIL_CODE=8"}, "checks", "owner/repo", "7")
			if run.exit != 8 || run.stdout != "" || strings.Contains(run.stderr, "fixture-canary") {
				t.Fatalf("failure mistaken for query data / raw diagnostics leaked: %#v", run)
			}
		})
	}
	for _, diagnostic := range []string{
		"HTTP 401: Bad credentials\n", "HTTP 403: API rate limit exceeded\n", "dial tcp: timeout\n",
		"GraphQL: Resource not accessible by personal access token (repository.pullRequest)\n",
		githubPermission + "HTTP 502: Bad Gateway\n",
		strings.TrimSuffix(githubPermission, "\n") + ", Internal server error (node)\n",
		"no checks reported on the 'other-branch' branch\n",
	} {
		t.Run(strings.TrimSpace(diagnostic), func(t *testing.T) {
			fixtures := githubFixtures()
			fixtures["checks-error"] = diagnostic
			run, calls := runGitHubScript(t, "pr_checks", fixtures, nil, "checks", "owner/repo", "7")
			if run.exit != 1 || run.stdout != "" || len(calls) != 2 {
				t.Fatalf("unrelated/mixed failure caused fallback: %#v, %#v", run, calls)
			}
		})
	}
}

func TestGitHubPRChecksRejectMalformedAndWrongIdentity(t *testing.T) {
	for _, test := range []struct{ name, phase, body string }{
		{"invalid details", "details", `null`},
		{"invalid sha", "details", `{"headRefOid":"../../escape","headRefName":"topic"}`},
		{"invalid checks", "checks", `{}`},
		{"invalid bucket", "checks", strings.Replace(githubFixtures()["checks"], `"pass"`, `"unknown"`, 1)},
		{"multi JSON checks", "checks", `[] []`},
		{"invalid statuses", "statuses", `{"message":"permission denied"}`},
		{"nested status description", "statuses", strings.Replace(githubFixtures()["statuses"], `"Not green"`, `{"opaque":"fixture-canary-do-not-replay"}`, 1)},
		{"nested status url", "statuses", strings.Replace(githubFixtures()["statuses"], `"https://ci.example/run"`, `{"opaque":"fixture-canary-do-not-replay"}`, 1)},
		{"wrong status sha", "statuses", strings.Replace(githubFixtures()["statuses"], githubHead, strings.Repeat("a", 40), 1)},
		{"negative run count", "runs", `{"total_count":-1,"workflow_runs":[]}`},
		{"wrong run sha", "runs", strings.Replace(githubFixtures()["runs"], githubHead, strings.Repeat("a", 40), 1)},
		{"path-like run id", "runs", strings.Replace(githubFixtures()["runs"], `"id":101`, `"id":"../../other"`, 1)},
		{"nested run conclusion", "runs", strings.Replace(githubFixtures()["runs"], `"conclusion":"failure"`, `"conclusion":{"opaque":"fixture-canary-do-not-replay"}`, 1)},
		{"nested run url", "runs", strings.Replace(githubFixtures()["runs"], `"html_url":"https://github.com/owner/repo/actions/runs/101"`, `"html_url":{"opaque":"fixture-canary-do-not-replay"}`, 1)},
		{"wrong job sha", "jobs", strings.Replace(githubFixtures()["jobs"], githubHead, strings.Repeat("a", 40), 1)},
		{"wrong attempt", "jobs", strings.Replace(githubFixtures()["jobs"], `"run_attempt":2`, `"run_attempt":1`, 1)},
		{"nested job conclusion", "jobs", strings.Replace(githubFixtures()["jobs"], `"conclusion":"failure"`, `"conclusion":{"opaque":"fixture-canary-do-not-replay"}`, 1)},
		{"head moved", "head", fmt.Sprintf(`{"headRefOid":%q}`, strings.Repeat("a", 40))},
	} {
		t.Run(test.name, func(t *testing.T) {
			fixtures := githubFixtures()
			fixtures[test.phase] = test.body
			if test.phase != "checks" {
				fixtures["checks-error"] = githubPermission
			}
			run, _ := runGitHubScript(t, "pr_checks", fixtures, nil, "checks", "owner/repo", "7")
			if run.exit == 0 || run.stdout != "" {
				t.Fatalf("invalid/wrong-identity data returned as success: %#v", run)
			}
		})
	}
}

func TestGitHubPRViewRejectsNestedAuthorAndBody(t *testing.T) {
	for _, replacement := range []struct{ old, value string }{
		{`"login":"dev"`, `"login":{"opaque":"fixture-canary-do-not-replay"}`},
		{`"body":"Keep the full body"`, `"body":{"opaque":"fixture-canary-do-not-replay"}`},
	} {
		fixtures := githubFixtures()
		fixtures["details"] = strings.Replace(fixtures["details"], replacement.old, replacement.value, 1)
		run, _ := runGitHubScript(t, "pr_checks", fixtures, nil, "view", "owner/repo", "7")
		if run.exit == 0 || run.stdout != "" || strings.Contains(run.stderr, "fixture-canary") {
			t.Fatalf("nested application data escaped: %#v", run)
		}
	}
	fixtures := githubFixtures()
	fixtures["details"] = strings.Replace(fixtures["details"], `{"login":"dev","unexpected_secret":"fixture-canary-do-not-replay"}`, `null`, 1)
	run, _ := runGitHubScript(t, "pr_checks", fixtures, nil, "view", "owner/repo", "7")
	if githubJSON(t, run)["author"] != nil {
		t.Fatal("deleted/unknown author must remain null")
	}
}

func TestGitHubPRLargeResultsUseFilesNotArgv(t *testing.T) {
	for _, fallback := range []bool{false, true} {
		fixtures := githubFixtures()
		if fallback {
			fixtures["checks-error"] = githubPermission
			fixtures["statuses"] = strings.Replace(fixtures["statuses"], "Not green", strings.Repeat("x", 160000), 1)
			fixtures["jobs"] = strings.Replace(fixtures["jobs"], `"name":"test"`, `"name":"`+strings.Repeat("y", 160000)+`"`, 1)
		} else {
			fixtures["checks"] = strings.Replace(fixtures["checks"], "A test failed", strings.Repeat("x", 320000), 1)
		}
		run, _ := runGitHubScript(t, "pr_checks", fixtures, nil, "view", "owner/repo", "7")
		result := githubJSON(t, run)
		if len(run.stdout) < 320000 || len(run.stdout) > 524288 || result["body"] != "Keep the full body" {
			t.Fatalf("large below-cap result lost: %d bytes, %#v", len(run.stdout), run)
		}
	}
}

func TestGitHubPRChecksBoundsAreExplicit(t *testing.T) {
	fixtures := githubFixtures()
	fixtures["checks-error"] = strings.TrimSuffix(githubPermission, "\n") + ", Resource not accessible by personal access token (node.commits.nodes.0.commit.statusCheckRollup.contexts.nodes.1)\n"
	var runs []string
	for i := 0; i < 11; i++ {
		runs = append(runs, fmt.Sprintf(`{"id":%d,"run_attempt":2,"head_sha":%q,"status":"completed","conclusion":"success"}`, 101+i, githubHead))
	}
	fixtures["runs"] = `{"total_count":201,"workflow_runs":[` + strings.Join(runs, ",") + `]}`
	fixtures["jobs"] = strings.Replace(fixtures["jobs"], `"total_count":1`, `"total_count":101`, 1)
	fixtures["statuses"] = strings.Replace(fixtures["statuses"], `"total_count":1`, `"total_count":101`, 1)
	run, calls := runGitHubScript(t, "pr_checks", fixtures, nil, "checks", "owner/repo", "7")
	result := githubJSON(t, run)
	actions := result["actions"].(map[string]any)
	if len(calls) != 15 || actions["truncated"] != true || len(actions["runs"].([]any)) != 10 || result["commit_status"].(map[string]any)["truncated"] != true {
		t.Fatalf("bounded fanout/partial pages: %#v, %d calls", result, len(calls))
	}
	for _, row := range actions["runs"].([]any) {
		if row.(map[string]any)["attempt_jobs"].(map[string]any)["truncated"] != true {
			t.Fatalf("omitted attempt jobs hidden: %#v", row)
		}
	}
	for _, phase := range []string{"checks", "details"} {
		fixtures := githubFixtures()
		mode := "checks"
		if phase == "checks" {
			fixtures[phase] = strings.Replace(fixtures[phase], "A test failed", strings.Repeat("x", 524288), 1)
		} else {
			mode = "view"
			fixtures[phase] = strings.Replace(fixtures[phase], "Keep the full body", strings.Repeat("x", 524288), 1)
		}
		run, _ := runGitHubScript(t, "pr_checks", fixtures, nil, mode, "owner/repo", "7")
		if run.exit == 0 || run.stdout != "" || !strings.Contains(run.stderr, "output bound") {
			t.Fatalf("oversized result silently clipped or succeeded: %#v", run)
		}
	}
}
