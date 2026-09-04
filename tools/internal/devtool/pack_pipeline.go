package devtool

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"go.yaml.in/yaml/v3"
)

// A shell pipeline exits with its LAST command's status, so `grep … | tail`
// reports success when the file is missing and the action is recorded as a
// successful read that found nothing. On the low, no-approval reads an operator
// or an LLM uses to check for errors, that empty output is a false all-clear.
//
// Authors guard the input first — see
// .agent/kb/rules/packs-pipelines-fail-on-source-errors.md, which also explains
// why `set -o pipefail` is the wrong fix (grep exits 1 on a legitimate
// no-match, so a clean log would become a failed action).
var pipelineSourceExemptActions = map[string]string{
	"forensics.gdb_backtrace": "gdb -batch exits 0 even when the attach fails, so propagating its " +
		"status enforces nothing. What keeps this honest instead: 2>&1 folds the failure text " +
		"into stdout at the top where head keeps it, the action is risk: high and " +
		"approval-gated, and 'The program is not being run.' is self-refuting rather than a " +
		"false all-clear.",
	"debugging.top_open_files": "lsof is a local enumerator whose empty answer is self-refuting — a " +
		"live host always holds open FDs, including the runner's own. lsof also exits 1 on any " +
		"listing failure, so propagating would invent alarms; a missing binary is covered by " +
		"requires.binaries.",
	"fw.conntrack_count": "already a precondition check: `conntrack -C` needs the same netlink " +
		"privileges as -L and runs first under `set -e`, so every module/privilege failure " +
		"aborts before the pipeline.",
	"fw.conntrack_list": "capture would buffer an unbounded table and head deliberately SIGPIPEs " +
		"conntrack after 1000 rows; a preceding `conntrack -C` probe needs the same netlink " +
		"privileges as -L and aborts before the pipeline.",
}

// Commands that open a path. A pipeline led by a local enumerator (ps, lsmod,
// ss) has no meaningful failure to mask and is not checked here.
// awk and sort are deliberately absent: `awk '{print $1}'` reads as a path
// operand and they never lead a source-reading pipeline in this catalog.
var pipelineFileReaders = map[string]bool{
	"cat":  true,
	"du":   true,
	"find": true,
	"grep": true,
	"head": true,
	"jq":   true,
	"ls":   true,
	"tail": true,
	"zcat": true,
}

// `pipefail` propagates a source failure and is the idiomatic answer in a bash
// script that owns its whole pipeline. It is still the wrong reach for a log
// grep — see the rule — because grep exits 1 on a legitimate no-match.
// Commands whose failure means "cannot see the target" rather than "nothing to
// report". Their own exit status is the truth, so the pipe is the only thing
// discarding it — unlike a file reader, there is no path to test first.
var pipelineRemoteSources = map[string]bool{
	"dmesg":                        true,
	"gdb":                          true,
	"jcmd":                         true,
	"jinfo":                        true,
	"jmap":                         true,
	"jstack":                       true,
	"journalctl":                   true,
	"kafka-broker-api-versions.sh": true,
	"kafka-configs.sh":             true,
	"kafka-consumer-groups.sh":     true,
	"kafka-topics.sh":              true,
	"kubectl":                      true,
	"lsof":                         true,
	"nomad":                        true,
	"pm2":                          true,
	"dig":                          true,
	"whois":                        true,
	"conntrack":                    true,
	// Local introspection whose failure still means "cannot see the target":
	// slabtop reads root-only /proc/slabinfo under a non-root runner, and
	// systemd-analyze needs a reachable manager. Both shipped piping into head,
	// so a denial recorded a successful low-risk read with empty output — and
	// this list is why the gate could not see it. An allowlist keyed on command
	// NAMES goes stale by construction; anything added here is one more name
	// the next author has to remember.
	"slabtop":         true,
	"systemd-analyze": true,
}

// A file test answers a question about ONE path, so it only covers a pipeline
// whose source is handed that same path. `[ -d /var/spool/postfix ]` says
// nothing about /var/spool/postfix/deferred — postfix keeps the queue
// directories mode 0700 under a traversable spool, so the guard passed, find
// was denied, and postfix.queue_counts reported 0 deferred messages on a host
// with thousands. The old heuristic accepted any guard text anywhere in the
// program as covering any pipeline in it, which is exactly how that shipped.
// `[[ -d P ]]` and `[ ! -r P ]` are the same test in other spellings.
var pipelinePathGuard = regexp.MustCompile(`(?:\[\[?|test)[ \t]+(?:![ \t]+)?-[rfdesx][ \t]+([^ \t\]]+)`)

// Capturing the source's status and exiting with it re-exposes what the pipe
// discarded, so it covers the whole program rather than one path.
var pipelineStatusGuards = []string{"exit $status", "exit $?"}

// Authors routinely test the literal and pipe the variable it was assigned to —
// postfix.maillog_grep picks between /var/log/mail.log and /var/log/maillog
// inside the guards, then greps "$log". Resolving the variable back to its
// assignments is what keeps that correct guard from reading as a missing one.
// A value this cannot parse simply is not a guarded path, so the variable stays
// uncovered.
var shellAssignment = regexp.MustCompile(`(?:^|[\s;])([A-Za-z_][A-Za-z0-9_]*)=([^\s;&|<>#]+)`)

type packPipelineAction struct {
	ID        string `yaml:"id"`
	Execution struct {
		Command struct {
			Binary string   `yaml:"binary"`
			Argv   []string `yaml:"argv"`
		} `yaml:"command"`
		Script struct {
			Path string `yaml:"path"`
		} `yaml:"script"`
	} `yaml:"execution"`
}

// actionShellSource returns the shell text an action runs — the `-c` program for
// an exec action, or the packaged script for a script action. A packaged script
// masks a source failure exactly the same way, and is where nomad.event_snapshot
// hid from the first pass of this check.
func actionShellSource(packDir string, action packPipelineAction) (string, bool, error) {
	if path := action.Execution.Script.Path; path != "" {
		script, err := os.ReadFile(filepath.Join(packDir, filepath.Clean(path)))
		if err != nil {
			return "", false, err
		}
		return string(script), true, nil
	}
	if action.Execution.Command.Binary != "/bin/sh" {
		return "", false, nil
	}
	program, ok := shellDashCProgram(action.Execution.Command.Argv)
	return program, ok, nil
}

func validatePackPipelineFailures(input packActionLintInput) error {
	var failures []string
	for _, path := range input.actionPaths {
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		var action packPipelineAction
		if err := yaml.Unmarshal(data, &action); err != nil {
			return fmt.Errorf("parse %s: %w", path, err)
		}
		if _, exempt := pipelineSourceExemptActions[action.ID]; exempt {
			continue
		}
		source, ok, err := actionShellSource(input.packDir, action)
		if err != nil {
			return err
		}
		if !ok {
			continue
		}
		if pipelineMasksSourceFailure(source) {
			failures = append(failures, action.ID)
		}
	}
	if len(failures) > 0 {
		return fmt.Errorf(
			"shell pipelines must fail when their source does; guard the input before piping into tail/head: %s",
			strings.Join(failures, ", "),
		)
	}
	return nil
}

func shellDashCProgram(argv []string) (string, bool) {
	for index, argument := range argv {
		if argument == "--" {
			return "", false
		}
		if len(argument) < 2 || argument[0] != '-' || argument[1] == '-' ||
			!strings.ContainsRune(argument[1:], 'c') {
			continue
		}
		if index+1 >= len(argv) {
			return "", false
		}
		return argv[index+1], true
	}
	return "", false
}

func pipelineMasksSourceFailure(program string) bool {
	// A guard text inside a grouped producer does not protect the outer pipe:
	// `{ source || exit 1; } | tail` still exits with tail's status. Inspect
	// those groups before asking whether the program's guards cover the source.
	// A real pipefail setup is the one global guard that protects the pipe.
	pipefail := false
	guards := pipelineProgramGuards(program)
	for _, line := range strings.Split(program, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		index := firstPipeIndex(line)
		if index >= 0 && pipelineSourceReadsPath(line[:index]) {
			if !pipefail && (pipelineSourceIsRemote(line[:index]) ||
				bracedPipelineSource(line[:index]) || !guards.cover(line[:index])) {
				return true
			}
		}
		if lineEnablesPipefail(line) {
			pipefail = true
		}
	}
	return false
}

func bracedPipelineSource(segment string) bool {
	segment = strings.TrimSpace(segment)
	return strings.HasPrefix(segment, "{") && strings.HasSuffix(segment, "}")
}

func pipelineSourceIsRemote(segment string) bool {
	segment = strings.TrimSpace(segment)
	if bracedPipelineSource(segment) {
		group := strings.TrimSpace(segment[1 : len(segment)-1])
		group = strings.TrimSpace(strings.TrimSuffix(group, ";"))
		for _, source := range splitUnquotedOr(group) {
			if pipelineSourceIsRemote(source) {
				return true
			}
		}
		return false
	}
	fields := pipelineSourceFields(segment)
	return len(fields) > 0 && pipelineRemoteSources[fields[0]]
}

// pipelineSourceFields reduces a pipeline's leading segment to the command that
// actually runs, stepping over the words a compound statement puts in front of
// it. Two of those hid the same pipeline twice over in postfix.queue_counts —
// `for q in …; do n=$(find "$d" … | wc -l)`: the `do` stopped the scanner
// before it read any command, and `n=$(find` looked like an environment
// assignment to strip rather than an assignment whose VALUE is the source. The
// action shipped reporting 0 deferred messages on a host with thousands.
func pipelineSourceFields(segment string) []string {
	fields := strings.Fields(strings.TrimSpace(lastUnquotedStatement(segment)))
	for len(fields) > 0 {
		field := fields[0]
		switch {
		case shellStatementKeywords[field]:
			fields = fields[1:]
		case strings.HasPrefix(field, "$("):
			fields[0] = field[2:]
		case strings.Contains(field, "=$("):
			fields[0] = field[strings.Index(field, "=$(")+3:]
		case strings.Contains(field, "=") && !strings.HasPrefix(field, "-"):
			fields = fields[1:]
		default:
			return fields
		}
		// A keyword or prefix can leave an empty field behind ("$(" alone).
		if len(fields) > 0 && fields[0] == "" {
			fields = fields[1:]
		}
	}
	return fields
}

// The words a compound statement can put between the line start and its real
// command. `!` is here because `! grep … | tail` still pipes grep.
var shellStatementKeywords = map[string]bool{
	"do": true, "then": true, "else": true, "!": true, "{": true, "(": true,
}

func lineEnablesPipefail(line string) bool {
	comment := indexUnquoted(line, func(line string, index int) bool {
		return line[index] == '#'
	})
	if comment >= 0 {
		line = line[:comment]
	}
	fields := strings.Fields(line)
	if len(fields) < 3 || fields[0] != "set" {
		return false
	}
	for index := 1; index < len(fields); index++ {
		if strings.TrimSuffix(fields[index], ";") != "pipefail" {
			continue
		}
		option := fields[index-1]
		if option == "-o" ||
			(strings.HasPrefix(option, "-") && strings.Contains(option[1:], "o")) {
			return true
		}
	}
	return false
}

// firstPipeIndex finds the first real pipe, stepping over the `||` and `|&`
// operators and over anything inside quotes. `cat a || cat b` propagates its own
// failure and is not a pipeline, and the alternation in
// `grep -E '(a|b)' "$1" | tail` is regex syntax, not shell.
func firstPipeIndex(line string) int {
	return indexUnquoted(line, func(line string, index int) bool {
		if line[index] != '|' {
			return false
		}
		if index+1 < len(line) && (line[index+1] == '|' || line[index+1] == '&') {
			return false
		}
		return index == 0 || line[index-1] != '|'
	})
}

// lastUnquotedStatement returns the final `;`-separated statement, ignoring any
// separator inside quotes — `SP=$(python -c 'import site; print(x)'); du …`
// is one assignment followed by the command that matters.
func lastUnquotedStatement(segment string) string {
	start := 0
	for {
		index := indexUnquotedFrom(segment, start, func(line string, index int) bool {
			return line[index] == ';'
		})
		if index < 0 {
			return segment[start:]
		}
		start = index + 1
	}
}

func indexUnquoted(line string, match func(string, int) bool) int {
	return indexUnquotedFrom(line, 0, match)
}

// indexUnquotedFrom scans from offset, tracking single- and double-quote spans,
// and returns the first index at or after it where match reports true outside
// any quoted span.
func indexUnquotedFrom(line string, offset int, match func(string, int) bool) int {
	var quote byte
	for index := 0; index < len(line); index++ {
		character := line[index]
		switch {
		case quote == '\'':
			if character == '\'' {
				quote = 0
			}
			continue
		case quote == '"':
			if character == '\\' {
				index++
			} else if character == '"' {
				quote = 0
			}
			continue
		case character == '\'', character == '"':
			quote = character
			continue
		}
		if index >= offset && match(line, index) {
			return index
		}
	}
	return -1
}

type pipelineGuards struct {
	status      bool
	paths       map[string]bool
	assignments map[string][]string
}

func pipelineProgramGuards(program string) pipelineGuards {
	guards := pipelineGuards{paths: map[string]bool{}, assignments: map[string][]string{}}
	for _, status := range pipelineStatusGuards {
		if strings.Contains(program, status) {
			guards.status = true
		}
	}
	for _, match := range pipelinePathGuard.FindAllStringSubmatch(program, -1) {
		guards.paths[normalizeShellPath(match[1])] = true
	}
	for _, match := range shellAssignment.FindAllStringSubmatch(program, -1) {
		guards.assignments[match[1]] = append(guards.assignments[match[1]], normalizeShellPath(match[2]))
	}
	return guards
}

// cover reports whether a guard in the program tested a path this pipeline's
// source is actually handed. A test on the directory a source WALKS counts —
// `[ -d "$1" ]` before `find "$1"` is the operand find receives — while a test
// on an ancestor, a sibling, or the guarded directory's entries does not:
// none of them proves the source can open what it is about to open.
func (g pipelineGuards) cover(segment string) bool {
	if g.status {
		return true
	}
	for _, path := range pipelineSourcePaths(segment) {
		if g.paths[path] || g.coversVariable(path) {
			return true
		}
	}
	return false
}

// A variable operand is covered only when EVERY value the program assigns it was
// guarded; one unguarded branch is a path that reaches the source untested.
func (g pipelineGuards) coversVariable(path string) bool {
	name := shellVariableName(path)
	if name == "" {
		return false
	}
	values := g.assignments[name]
	if len(values) == 0 {
		return false
	}
	for _, value := range values {
		if !g.paths[value] {
			return false
		}
	}
	return true
}

// shellVariableName reads the name out of a bare `$log` or `${log}` operand and
// returns "" for anything else — `$SP/*` and `/var/spool/postfix/$q` are paths
// BUILT from a variable, so the guarded value is not what the source is handed.
var bareShellVariable = regexp.MustCompile(`^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$`)

func shellVariableName(path string) string {
	match := bareShellVariable.FindStringSubmatch(path)
	if match == nil {
		return ""
	}
	return match[1]
}

// pipelineSourcePaths returns the normalized path operands the leading
// file-reading command of a pipeline is given.
func pipelineSourcePaths(segment string) []string {
	segment = strings.TrimSpace(segment)
	if bracedPipelineSource(segment) {
		group := strings.TrimSpace(segment[1 : len(segment)-1])
		group = strings.TrimSpace(strings.TrimSuffix(group, ";"))
		var paths []string
		for _, source := range splitUnquotedOr(group) {
			paths = append(paths, pipelineSourcePaths(source)...)
		}
		return paths
	}
	fields := pipelineSourceFields(segment)
	if len(fields) == 0 || !pipelineFileReaders[fields[0]] {
		return nil
	}
	var paths []string
	for _, operand := range fields[1:] {
		if shellOperandIsPath(operand) {
			paths = append(paths, normalizeShellPath(operand))
		}
	}
	return paths
}

// pipelineSourceReadsPath reports whether the leading segment of a pipeline
// runs a file-reading command against a path operand.
func pipelineSourceReadsPath(segment string) bool {
	segment = strings.TrimSpace(segment)
	if strings.HasPrefix(segment, "{") && strings.HasSuffix(segment, "}") {
		group := strings.TrimSpace(segment[1 : len(segment)-1])
		group = strings.TrimSpace(strings.TrimSuffix(group, ";"))
		for _, source := range splitUnquotedOr(group) {
			if pipelineSourceReadsPath(source) {
				return true
			}
		}
		return false
	}
	fields := pipelineSourceFields(segment)
	if len(fields) == 0 {
		return false
	}
	if pipelineRemoteSources[fields[0]] {
		return true
	}
	return len(pipelineSourcePaths(segment)) > 0
}

func splitUnquotedOr(segment string) []string {
	var parts []string
	start := 0
	for {
		index := indexUnquotedFrom(segment, start, func(line string, index int) bool {
			return line[index] == '|' && index+1 < len(line) && line[index+1] == '|'
		})
		if index < 0 {
			return append(parts, segment[start:])
		}
		parts = append(parts, segment[start:index])
		start = index + 2
	}
}

// normalizeShellPath drops the quoting an author may or may not have used — and
// may have used mid-operand, as in `"$SP"/*` — so a guard and the read it
// protects compare as the same expression.
func normalizeShellPath(operand string) string {
	return strings.NewReplacer(`"`, "", `'`, "").Replace(operand)
}

func shellOperandIsPath(operand string) bool {
	unquoted := normalizeShellPath(operand)
	switch {
	case strings.HasPrefix(unquoted, "/"):
		return true
	case strings.HasPrefix(unquoted, "$"), strings.HasPrefix(unquoted, "${"):
		return true
	default:
		return false
	}
}
