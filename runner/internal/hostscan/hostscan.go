// Package hostscan inspects the local host to recommend which action
// packs are worth installing. It detects which service binaries are
// present — on $PATH, in the standard bin dirs, or running right now as
// a process — and matches that evidence against the catalog's per-pack
// requirements. The detection is deliberately path-agnostic: a service
// binary shipped in /usr/local/bin (or running from /opt) counts the
// same as one on $PATH, so a trimmed root PATH never hides a service
// that's plainly there.
package hostscan

import (
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
)

// standardBinDirs are searched in addition to $PATH so we still find a
// service binary the installing shell's PATH happens to miss — e.g.
// nomad shipped in /usr/local/bin on a host whose root PATH is trimmed.
var standardBinDirs = []string{
	"/usr/local/sbin", "/usr/local/bin",
	"/usr/sbin", "/usr/bin",
	"/sbin", "/bin",
	"/opt/bin",
}

// PackReq is the slice of a pack manifest the suggester matches on.
type PackReq struct {
	ID       string
	Name     string
	OS       []string
	Binaries []string
}

// MatchesHostOS reports whether this pack's OS allowlist includes the
// current host OS (an empty list matches any OS).
func (r PackReq) MatchesHostOS() bool { return osMatches(r.OS) }

// Facts is what we observed about the host: where each probed binary was
// found, and the set of basenames of currently-running processes.
type Facts struct {
	// Binaries maps a probed binary name (lowercased) to where it was
	// found on disk.
	Binaries map[string]string
	// Running is the set of lowercased basenames of running processes.
	Running map[string]bool
}

// available reports whether binary bin is present by any signal and, if
// so, a short label for why — used to explain the match to the operator.
// A running process wins over a static binary because it's the stronger
// "this service is actually here" signal.
func (f Facts) available(bin string) (why string, ok bool) {
	b := strings.ToLower(bin)
	if f.Running[b] {
		return "running", true
	}
	if p := f.Binaries[b]; p != "" {
		return p, true
	}
	return "", false
}

// Suggestion is one matched pack plus the evidence behind the match.
type Suggestion struct {
	ID       string   `json:"id"`
	Name     string   `json:"name"`
	Evidence []string `json:"evidence"` // e.g. ["nomad (running)", "consul (/usr/bin/consul)"]
}

// genericHelpers are tools present on nearly every host (curl, nc, …) and
// used by many packs only to TALK to a service over its API. Their
// presence says nothing about which services actually run here, so they
// must not be the signal that earns a recommendation: "this host has curl"
// can't recommend grafana. They still count toward "all required present"
// (a pack that needs curl can't run without it) — they just don't
// discriminate one host from another.
var genericHelpers = map[string]bool{
	"curl": true, "wget": true, "nc": true, "ncat": true, "netcat": true,
	"socat": true, "jq": true, "openssl": true,
}

// Match returns the packs worth recommending for this host, in stable id
// order. A pack qualifies when its OS matches, EVERY required binary is
// present, AND at least one of those present requirements is specific to a
// service rather than a ubiquitous helper.
//
// The two rules work together: "all required present" keeps a pack the host
// can't run from being suggested and stops a co-listed helper from matching
// a service pack on its own (consul needs the `consul` binary, not just
// `curl`); the "discriminating signal" rule stops a pack whose ONLY
// requirement is a ubiquitous helper (grafana → curl) from matching on
// every host. Packs with no required binaries are the caller's baseline,
// not a host signal, and never match here.
func Match(reqs []PackReq, f Facts) []Suggestion {
	var out []Suggestion
	for _, r := range reqs {
		if len(r.Binaries) == 0 || !r.MatchesHostOS() {
			continue
		}
		evidence := make([]string, 0, len(r.Binaries))
		matched := true
		discriminating := false
		for _, b := range r.Binaries {
			why, ok := f.available(b)
			if !ok {
				matched = false
				break
			}
			evidence = append(evidence, b+" ("+why+")")
			// A binary specific to a service (not a ubiquitous helper) is
			// the real "this service is here" signal.
			if !genericHelpers[strings.ToLower(b)] {
				discriminating = true
			}
		}
		if matched && discriminating {
			out = append(out, Suggestion{ID: r.ID, Name: r.Name, Evidence: evidence})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

func osMatches(list []string) bool {
	if len(list) == 0 {
		return true
	}
	for _, o := range list {
		if o == runtime.GOOS {
			return true
		}
	}
	return false
}

// Detect probes the host for the given candidate binary names and the
// set of running processes. binaryNames is the union of the catalog's
// required binaries — we probe only what some pack actually cares about,
// rather than enumerating all of $PATH.
func Detect(binaryNames []string) Facts {
	return Facts{
		Binaries: scanBinaries(binaryNames, standardBinDirs),
		Running:  scanProcesses("/proc"),
	}
}

// SystemdPresent reports whether this host is running systemd, the gate
// for recommending the systemd-deep baseline pack.
func SystemdPresent() bool {
	fi, err := os.Stat("/run/systemd/system")
	return err == nil && fi.IsDir()
}

// scanBinaries resolves each name against the process $PATH, then the
// standard dirs, returning name->path for those found.
func scanBinaries(names, dirs []string) map[string]string {
	pathDirs := filepath.SplitList(os.Getenv("PATH"))
	found := make(map[string]string)
	for _, raw := range names {
		name := strings.ToLower(strings.TrimSpace(raw))
		if name == "" || found[name] != "" {
			continue
		}
		if p := firstExecutable(name, pathDirs); p != "" {
			found[name] = p
			continue
		}
		if p := firstExecutable(name, dirs); p != "" {
			found[name] = p
		}
	}
	return found
}

// firstExecutable returns the first dir+name that is a regular,
// executable file, or "" if none. We resolve by explicit dir list
// rather than exec.LookPath so the standard-dir fallback and the $PATH
// search share one code path and one notion of "executable".
func firstExecutable(name string, dirs []string) string {
	for _, d := range dirs {
		if d == "" {
			continue
		}
		p := filepath.Join(d, name)
		if isExecutableFile(p) {
			return p
		}
	}
	return ""
}

func isExecutableFile(p string) bool {
	fi, err := os.Stat(p)
	if err != nil || fi.IsDir() {
		return false
	}
	return fi.Mode().Perm()&0o111 != 0
}

// scanProcesses returns the set of lowercased basenames of running
// processes by reading <procRoot>/<pid>/{cmdline,comm}. On a host
// without /proc (macOS, etc.) it returns an empty set — binary
// detection still covers those hosts.
func scanProcesses(procRoot string) map[string]bool {
	out := make(map[string]bool)
	entries, err := os.ReadDir(procRoot)
	if err != nil {
		return out
	}
	for _, e := range entries {
		if !e.IsDir() || !isAllDigits(e.Name()) {
			continue
		}
		for _, name := range processNames(procRoot, e.Name()) {
			out[name] = true
		}
	}
	return out
}

// processNames reads the executable basenames for one pid from BOTH
// cmdline (argv0 — untruncated, may be an absolute path) and comm (the
// kernel's name, truncated to 15 chars). Both are recorded because a
// daemon that rewrites its argv (postgres → "postgres: writer process")
// hides its real name from cmdline but still exposes it in comm, while a
// long name truncated in comm survives in full in cmdline.
func processNames(procRoot, pid string) []string {
	var names []string
	if b, err := os.ReadFile(filepath.Join(procRoot, pid, "cmdline")); err == nil {
		argv0 := string(b)
		if z := strings.IndexByte(argv0, 0); z >= 0 {
			argv0 = argv0[:z]
		}
		if argv0 = strings.TrimSpace(argv0); argv0 != "" {
			names = append(names, strings.ToLower(filepath.Base(argv0)))
		}
	}
	if b, err := os.ReadFile(filepath.Join(procRoot, pid, "comm")); err == nil {
		if c := strings.ToLower(strings.TrimSpace(string(b))); c != "" {
			names = append(names, c)
		}
	}
	return names
}

func isAllDigits(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}
