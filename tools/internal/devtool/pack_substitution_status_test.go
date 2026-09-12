package devtool

import (
	"bytes"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// `set -e` is not inherited into a command substitution, so a helper a script
// calls as `value=$(helper …)` runs with its failure floor effectively off, and
// a bare `x=$(src)` inside it discards the source's status. Four captures in
// three packaged scripts shipped that shape and now take the status in place
// with `|| exit $?`:
//
//   - spark_api.sh's `driver_app_id`, reached as `app_id=$(driver_app_id)` from
//     both kill paths. An unreachable driver UI left `id` empty and the emptiness
//     check answered "no application is running on the driver UI" — so one run
//     printed the transfer failure AND the opposite fact about the deployment,
//     on a kill path;
//   - state_metadata.sh's `file_metadata`, reached as
//     `candidate=$(file_metadata …)` from `compare`. A rejected candidate fell
//     through to `project_metadata candidate <"$candidate"` with an empty path,
//     so what ended the run was `: No such file or directory` rather than the
//     refusal `candidate_path` had already printed;
//   - and both `size=$(stat -c %s -- …)` captures, in state_metadata.sh's
//     `candidate_path` and plan_summary.sh's `plan_path`. Bash reads an empty
//     variable as 0 in arithmetic, so a failed `stat` made `((size <= max))`
//     pass instead of refuse: `state_metadata file` returned exit 0 with a
//     complete projection and the declared 64 MiB bound simply did not apply.
//
// The behavior plans in packs/spark/test/cases.yaml and
// packs/terraform-readonly/test/cases.yaml cannot reach any of these rows. They
// boot a live Spark driver, so nothing there makes the driver UI unreachable
// while the case still runs, and no fixture file can make `stat` fail — a
// Compose fixture cannot shadow a coreutils binary inside the SUT, which is the
// only seam the two size captures have. So the seams here are a loopback server
// the test can kill or make answer 503, and a stub `stat`. The scripts executed
// are the real packaged ones, not copies of their logic.
//
// Every failure row is paired with a positive control, so a future "fix" that
// simply refuses more cannot pass: a genuinely empty application list still
// reports "no application is running", a reachable driver still kills and reads
// the job back, both size bounds still refuse one byte past and still pass
// exactly at the bound, and `compare` still reports a good candidate's relation.

// ------------------------------------------------------------------- spark

const (
	sparkNoApplicationText = "no application is running on the driver UI"
	sparkTransferText      = "Spark request failed with transfer status"
)

// sparkDriver is the driver UI the kill paths talk to: the one monitoring
// endpoint `driver_app_id` resolves the application from, the two kill
// endpoints, and the read-back the kill paths report from. It records the kill
// requests it received, which is how a row proves the script never reached the
// mutation after the resolution failed.
type sparkDriver struct {
	// applications is the body served for GET /api/v1/applications.
	applications string
	// status, when non-zero, replaces that body with a bare error status.
	status int

	mu     sync.Mutex
	killed []string
}

func (d *sparkDriver) kills() []string {
	d.mu.Lock()
	defer d.mu.Unlock()
	return append([]string(nil), d.killed...)
}

func (d *sparkDriver) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	switch {
	case path == "/api/v1/applications":
		if d.status != 0 {
			http.Error(w, "driver UI is not serving the monitoring API", d.status)
			return
		}
		fmt.Fprint(w, d.applications)
	case path == "/jobs/job/kill/" || path == "/stages/stage/kill/":
		d.mu.Lock()
		d.killed = append(d.killed, path+"?"+r.URL.RawQuery)
		d.mu.Unlock()
	case strings.HasSuffix(path, "/jobs/12"):
		fmt.Fprint(w, `{"jobId":12,"name":"count at Main.scala:9","status":"FAILED",`+
			`"numActiveTasks":0,"numFailedTasks":0,"numKilledTasks":4}`)
	case strings.HasSuffix(path, "/stages/3"):
		fmt.Fprint(w, `[{"stageId":3,"attemptId":0,"status":"FAILED",`+
			`"numActiveTasks":0,"numFailedTasks":0,"numKilledTasks":4}]`)
	default:
		http.Error(w, "unexpected path "+path, http.StatusNotFound)
	}
}

// A driver UI that cannot be reached, or that answers the monitoring API with an
// error, is not a driver UI with no application on it. Before the guard the
// script said both, and then exited on the emptiness check rather than on the
// transfer — so the operator reading a failed kill was told the deployment was
// idle.
func TestSparkKillPathsCarryAnUnreachableDriverUI(t *testing.T) {
	tests := []struct {
		name string
		argv []string
		// dead closes the server before the script runs; status otherwise makes
		// the monitoring endpoint answer with that HTTP status.
		dead   bool
		status int
		// transfer is curl's exit status the script has to report.
		transfer string
	}{
		{name: "job kill, driver UI refuses the connection", argv: []string{"job-kill", "12"}, dead: true, transfer: "7"},
		{name: "stage kill, driver UI refuses the connection", argv: []string{"stage-kill", "3"}, dead: true, transfer: "7"},
		{name: "job kill, driver UI answers 503", argv: []string{"job-kill", "12"}, status: http.StatusServiceUnavailable, transfer: "22"},
		{name: "stage kill, driver UI answers 503", argv: []string{"stage-kill", "3"}, status: http.StatusServiceUnavailable, transfer: "22"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			driver := &sparkDriver{applications: `[{"id":"app-20260912"}]`, status: test.status}
			server := httptest.NewServer(driver)
			defer server.Close()
			if test.dead {
				// A closed httptest server leaves a port nothing is listening
				// on, which is a connection refusal rather than a timeout.
				server.Close()
			}
			run := runPackagedScript(t, sparkScript(t), nil,
				[]string{"SPARK_UI_URL=" + server.URL}, test.argv...)
			if run.exit == 0 {
				t.Fatalf("exit = 0 on a driver UI that never answered (stdout %q)", run.stdout)
			}
			if !strings.Contains(run.stderr, sparkTransferText+" "+test.transfer) {
				t.Fatalf("stderr = %q, want the transfer status %s", run.stderr, test.transfer)
			}
			if strings.Contains(run.stderr, sparkNoApplicationText) {
				t.Fatalf("an unreachable driver UI was also diagnosed as idle: %q", run.stderr)
			}
			if run.stdout != "" {
				t.Fatalf("a failed resolution still produced a result: %q", run.stdout)
			}
			if kills := driver.kills(); len(kills) != 0 {
				t.Fatalf("the kill was issued after the resolution failed: %v", kills)
			}
		})
	}
}

// The other half of the same check: an application list that really is empty is
// still reported as an idle driver, and a driver with an application still kills
// and reads the outcome back. Without these the guard could be "fixed" by
// refusing every resolution.
func TestSparkKillPathsKeepTheirAnswers(t *testing.T) {
	t.Run("an empty application list is still an idle driver", func(t *testing.T) {
		driver := &sparkDriver{applications: `[]`}
		server := httptest.NewServer(driver)
		defer server.Close()
		run := runPackagedScript(t, sparkScript(t), nil,
			[]string{"SPARK_UI_URL=" + server.URL}, "job-kill", "12")
		if run.exit != 1 {
			t.Fatalf("exit = %d, want 1 (stderr %q)", run.exit, run.stderr)
		}
		if !strings.Contains(run.stderr, sparkNoApplicationText) {
			t.Fatalf("stderr = %q, want the idle-driver refusal", run.stderr)
		}
		if strings.Contains(run.stderr, sparkTransferText) {
			t.Fatalf("an answered request was reported as a failed transfer: %q", run.stderr)
		}
		if kills := driver.kills(); len(kills) != 0 {
			t.Fatalf("the kill was issued with no application resolved: %v", kills)
		}
	})

	tests := []struct {
		name     string
		argv     []string
		wantKill string
		wantJSON string
	}{
		{
			name:     "job kill",
			argv:     []string{"job-kill", "12"},
			wantKill: "/jobs/job/kill/?id=12",
			wantJSON: `"jobId":12`,
		},
		{
			name:     "stage kill",
			argv:     []string{"stage-kill", "3"},
			wantKill: "/stages/stage/kill/?id=3",
			wantJSON: `"stageId":3`,
		},
	}
	for _, test := range tests {
		t.Run(test.name+" on a live driver still reports the outcome", func(t *testing.T) {
			driver := &sparkDriver{applications: `[{"id":"app-20260912"}]`}
			server := httptest.NewServer(driver)
			defer server.Close()
			run := runPackagedScript(t, sparkScript(t), nil,
				[]string{"SPARK_UI_URL=" + server.URL}, test.argv...)
			if run.exit != 0 {
				t.Fatalf("exit = %d, want 0 (stderr %q)", run.exit, run.stderr)
			}
			if !strings.Contains(run.stdout, test.wantJSON) ||
				!strings.Contains(run.stdout, `"status":"FAILED"`) {
				t.Fatalf("stdout = %q, want the read-back outcome", run.stdout)
			}
			if kills := driver.kills(); len(kills) != 1 || kills[0] != test.wantKill {
				t.Fatalf("kills = %v, want exactly [%s]", kills, test.wantKill)
			}
		})
	}
}

func sparkScript(t *testing.T) string {
	t.Helper()
	return packagedScript(t, "spark", "spark_api.sh")
}

// --------------------------------------------------------- terraform-readonly

// The size bounds the two scripts enforce, and the messages they owe the
// operator when a file is over one.
const (
	tfPlanBound     = 33554432
	tfStateBound    = 67108864
	tfPlanOverText  = "saved plan exceeded 32 MiB"
	tfStateOverText = "candidate Terraform state exceeded 64 MiB"
)

// The stub `stat`. It fails, or reports a size, only for the `-c` form the two
// scripts use to read a file size, and execs the real binary for anything else:
// a stub that failed every call would prove the script notices a broken PATH
// rather than that it carries the size capture's status out of the
// substitution. Reporting a size is how the over-bound rows stay cheap — the
// alternative is writing a 32 MiB and a 64 MiB file per row.
const tfStubStat = `#!/bin/bash
for arg in "$@"; do
  if [ "$arg" = "-c" ]; then
    if [ -n "${STUB_STAT_RC:-}" ]; then
      printf 'stub: stat failed\n' >&2
      exit "$STUB_STAT_RC"
    fi
    if [ -n "${STUB_STAT_SIZE:-}" ]; then
      printf '%%s\n' "$STUB_STAT_SIZE"
      exit 0
    fi
  fi
done
exec %s "$@"
`

// The stub `terraform`. Only the two read subcommands these paths reach are
// served; anything else is a loud failure rather than a quiet empty answer.
const tfStubTerraform = `#!/bin/bash
set -uo pipefail
case "${1:-}" in
  show) printf '%s\n' '` + tfPlanDocument + `' ;;
  state) printf '%s\n' '` + tfLiveState + `' ;;
  *) printf 'stub: unexpected argv: %s\n' "$*" >&2; exit 90 ;;
esac
`

const (
	tfPlanDocument = `{"format_version":"1.2","terraform_version":"1.9.5","resource_changes":` +
		`[{"address":"null_resource.a","type":"null_resource","module_address":"",` +
		`"change":{"actions":["create"]}}]}`
	tfLiveState = `{"version":4,"terraform_version":"1.9.5","serial":7,` +
		`"lineage":"3a2b1c00-0000-4000-8000-000000000001","resources":[]}`
	// Same lineage, lower serial, so `compare` has one predictable relation.
	tfCandidateState = `{"version":4,"terraform_version":"1.9.5","serial":5,` +
		`"lineage":"3a2b1c00-0000-4000-8000-000000000001","resources":[]}`
)

// A `stat` that fails leaves `size` empty, and bash reads an empty variable as 0
// in arithmetic — so before the guard the bound passed and the action answered
// with a complete projection at exit 0. The status has to end the run instead,
// and it has to be `stat`'s own, because the operator needs to see that the file
// could not be measured rather than that it was small enough.
func TestTerraformReadonlySizeCapturesCarryAFailedStat(t *testing.T) {
	tests := []struct {
		name string
		// script and mode name the packaged script and its subcommand.
		script string
		argv   []string
		rc     string
		// forbidden is the projection field a false success would carry.
		forbidden string
	}{
		{
			name:      "saved plan resolution",
			script:    "plan_summary.sh",
			argv:      []string{"file", "review.tfplan"},
			rc:        "7",
			forbidden: "plan_file",
		},
		{
			name:      "candidate state resolution",
			script:    "state_metadata.sh",
			argv:      []string{"file", "candidate.tfstate"},
			rc:        "9",
			forbidden: "state_format_version",
		},
		{
			// `compare` reaches the same capture through a second
			// substitution-crossing hop, so this row proves the two guards
			// compose rather than only the inner one firing.
			name:      "candidate state resolution reached through compare",
			script:    "state_metadata.sh",
			argv:      []string{"compare", "candidate.tfstate"},
			rc:        "9",
			forbidden: "relation",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			run := runTerraformReadonly(t, test.script, []string{"STUB_STAT_RC=" + test.rc}, test.argv...)
			if got := fmt.Sprint(run.exit); got != test.rc {
				t.Fatalf("exit = %s, want stat's %s (stderr %q)", got, test.rc, run.stderr)
			}
			if strings.Contains(run.stdout, test.forbidden) {
				t.Fatalf("an unmeasurable file still produced a result: %q", run.stdout)
			}
		})
	}
}

// The other half: taking the status must not retire the bound the capture feeds.
// Both scripts still refuse one byte past their declared limit with the authored
// message, and still accept a file exactly at it.
func TestTerraformReadonlySizeBoundsStillDecide(t *testing.T) {
	tests := []struct {
		name    string
		script  string
		argv    []string
		size    int
		refused string
		// wanted is the projection field a permitted file has to produce.
		wanted string
	}{
		{
			name:   "saved plan at the bound",
			script: "plan_summary.sh",
			argv:   []string{"file", "review.tfplan"},
			size:   tfPlanBound,
			wanted: `"source":"plan_file"`,
		},
		{
			name:    "saved plan one byte past the bound",
			script:  "plan_summary.sh",
			argv:    []string{"file", "review.tfplan"},
			size:    tfPlanBound + 1,
			refused: tfPlanOverText,
		},
		{
			name:   "candidate state at the bound",
			script: "state_metadata.sh",
			argv:   []string{"file", "candidate.tfstate"},
			size:   tfStateBound,
			wanted: `"source":"candidate"`,
		},
		{
			name:    "candidate state one byte past the bound",
			script:  "state_metadata.sh",
			argv:    []string{"file", "candidate.tfstate"},
			size:    tfStateBound + 1,
			refused: tfStateOverText,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			run := runTerraformReadonly(t, test.script,
				[]string{fmt.Sprintf("STUB_STAT_SIZE=%d", test.size)}, test.argv...)
			if test.refused != "" {
				if run.exit != 1 {
					t.Fatalf("exit = %d, want 1 (stderr %q)", run.exit, run.stderr)
				}
				if !strings.Contains(run.stderr, test.refused) {
					t.Fatalf("stderr = %q, want the authored size message", run.stderr)
				}
				if strings.Contains(run.stdout, "source") {
					t.Fatalf("an over-bound file still produced a result: %q", run.stdout)
				}
				return
			}
			if run.exit != 0 {
				t.Fatalf("exit = %d, want 0 (stderr %q)", run.exit, run.stderr)
			}
			if !strings.Contains(run.stdout, test.wanted) {
				t.Fatalf("stdout = %q, want a projection (stderr %q)", run.stdout, run.stderr)
			}
		})
	}
}

// `compare` resolves its candidate through `candidate=$(file_metadata …)`, so
// before the guard a candidate `candidate_path` had already refused fell through
// to `project_metadata candidate <"$candidate"` with an empty path: the run ended
// on bash's redirect error and the refusal the operator needed was buried above
// an unrelated `: No such file or directory`.
func TestTerraformReadonlyCompareCarriesACandidateRefusal(t *testing.T) {
	tests := []struct {
		name string
		// candidate is the basename asked for; absent means it is never created.
		candidate string
		directory bool
		refusal   string
	}{
		{
			name:      "candidate that does not exist",
			candidate: "missing.tfstate",
			refusal:   "candidate state file does not exist",
		},
		{
			name:      "candidate that is not a regular file",
			candidate: "adirectory.tfstate",
			directory: true,
			refusal:   "candidate state file must be a readable regular file",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			workspace := terraformWorkspace(t)
			if test.directory {
				if err := os.Mkdir(filepath.Join(workspace.candidateDir, test.candidate), 0o755); err != nil {
					t.Fatal(err)
				}
			}
			run := workspace.run(t, "state_metadata.sh", nil, "compare", test.candidate)
			if run.exit != 1 {
				t.Fatalf("exit = %d, want 1 (stderr %q)", run.exit, run.stderr)
			}
			if !strings.Contains(run.stderr, test.refusal) {
				t.Fatalf("stderr = %q, want the authored refusal", run.stderr)
			}
			// The empty-path redirect reads `state_metadata.sh: line 113: : No
			// such file or directory` — bash's own diagnostic, with the script
			// and a line number in it. Every authored refusal goes through
			// `fail` and carries no such prefix, so the absence of one is what
			// separates the two runs. Matching the bare message would not:
			// `realpath -e` prints it too, on the row it is meant to refuse.
			if strings.Contains(run.stderr, "state_metadata.sh: line") {
				t.Fatalf("the run ended on a bash-level error, not the refusal: %q", run.stderr)
			}
			if strings.Contains(run.stdout, "relation") {
				t.Fatalf("a refused candidate still produced a comparison: %q", run.stdout)
			}
		})
	}
}

// And a candidate that passes every check still compares, with the real `stat`.
func TestTerraformReadonlyKeepsItsProjections(t *testing.T) {
	tests := []struct {
		name   string
		script string
		argv   []string
		wanted []string
	}{
		{
			name:   "saved plan summary",
			script: "plan_summary.sh",
			argv:   []string{"file", "review.tfplan"},
			wanted: []string{`"source":"plan_file"`, `"create":1`},
		},
		{
			name:   "candidate state metadata",
			script: "state_metadata.sh",
			argv:   []string{"file", "candidate.tfstate"},
			wanted: []string{`"source":"candidate"`, `"serial":5`},
		},
		{
			name:   "live and candidate comparison",
			script: "state_metadata.sh",
			argv:   []string{"compare", "candidate.tfstate"},
			wanted: []string{`"relation":"candidate_older"`, `"serial_delta":-2`},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			run := runTerraformReadonly(t, test.script, nil, test.argv...)
			if run.exit != 0 {
				t.Fatalf("exit = %d, want 0 (stderr %q)", run.exit, run.stderr)
			}
			for _, want := range test.wanted {
				if !strings.Contains(run.stdout, want) {
					t.Fatalf("stdout = %q, want %s", run.stdout, want)
				}
			}
		})
	}
}

// terraformFixture is the disposable workspace the terraform-readonly rows run
// against: a plan directory holding one saved plan, a candidate directory
// holding one candidate state, and the working directory the scripts require.
type terraformFixture struct {
	dir          string
	planDir      string
	candidateDir string
}

func terraformWorkspace(t *testing.T) terraformFixture {
	t.Helper()
	root := t.TempDir()
	fixture := terraformFixture{
		dir:          filepath.Join(root, "workspace"),
		planDir:      filepath.Join(root, "plans"),
		candidateDir: filepath.Join(root, "candidates"),
	}
	for _, dir := range []string{fixture.dir, fixture.planDir, fixture.candidateDir} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	// The saved plan's bytes never matter: the scripts resolve and measure it,
	// and the stub `terraform show -json` is what reads it back.
	writeFixtureFile(t, filepath.Join(fixture.planDir, "review.tfplan"), "saved plan\n")
	writeFixtureFile(t, filepath.Join(fixture.candidateDir, "candidate.tfstate"), tfCandidateState+"\n")
	return fixture
}

func (f terraformFixture) run(t *testing.T, script string, env []string, argv ...string) packScriptRun {
	t.Helper()
	stat, err := exec.LookPath("stat")
	if err != nil {
		t.Fatalf("locate stat: %v", err)
	}
	stubs := []packScriptStub{
		{name: "stat", body: fmt.Sprintf(tfStubStat, stat)},
		{name: "terraform", body: tfStubTerraform},
	}
	env = append(env,
		"TF_DIR="+f.dir,
		"TF_PLAN_DIR="+f.planDir,
		"TF_STATE_CANDIDATE_DIR="+f.candidateDir)
	return runPackagedScript(t, packagedScript(t, "terraform-readonly", script), stubs, env, argv...)
}

func runTerraformReadonly(t *testing.T, script string, env []string, argv ...string) packScriptRun {
	t.Helper()
	return terraformWorkspace(t).run(t, script, env, argv...)
}

func writeFixtureFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

// ------------------------------------------------------------------ harness

type packScriptRun struct {
	stdout string
	stderr string
	exit   int
}

// packScriptStub is a PATH binary to shadow ahead of the real one, and the body
// that shadows it.
type packScriptStub struct{ name, body string }

// packagedScript resolves one pack's shipped script, so a row runs the exact
// bytes the runner executes rather than a copy of their logic.
func packagedScript(t *testing.T, pack, name string) string {
	t.Helper()
	script := filepath.Join("..", "..", "..", "packs", pack, "scripts", name)
	if _, err := os.Stat(script); err != nil {
		t.Fatalf("packaged script: %v", err)
	}
	return script
}

// runPackagedScript runs a packaged script under bash with the given stubs first
// on PATH. The environment is closed: only PATH and what the row names, so a
// credential or a TF_* variable in the developer's shell cannot change a result.
func runPackagedScript(t *testing.T, script string, stubs []packScriptStub, env []string, argv ...string) packScriptRun {
	t.Helper()
	path := os.Getenv("PATH")
	if len(stubs) > 0 {
		bin := t.TempDir()
		for _, stub := range stubs {
			if err := os.WriteFile(filepath.Join(bin, stub.name), []byte(stub.body), 0o755); err != nil {
				t.Fatal(err)
			}
		}
		path = bin + string(os.PathListSeparator) + path
	}
	cmd := exec.Command("bash", append([]string{script}, argv...)...)
	cmd.Env = append(env, "PATH="+path)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	run := packScriptRun{stdout: stdout.String(), stderr: stderr.String()}
	var exitErr *exec.ExitError
	switch {
	case err == nil:
	case errors.As(err, &exitErr):
		run.exit = exitErr.ExitCode()
	default:
		t.Fatalf("run script: %v", err)
	}
	return run
}
