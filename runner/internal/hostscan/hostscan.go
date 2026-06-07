// Package hostscan inspects the local host to recommend which action
// packs are worth installing. For each candidate pack it checks a
// "detect" signal — service-specific binaries present, service processes
// running, or service ports listening — and recommends the pack when any
// of those fire.
//
// Detection is path-agnostic: a binary in /usr/local/bin or /opt counts
// the same as one on $PATH. And the policy of WHICH binaries are too
// generic to be a signal (curl, nc, …) lives server-side — the portal
// strips ubiquitous helpers from each pack's detect signal before the
// runner ever sees it — so this package is pure mechanism: "is this
// signal present on this host?". That keeps the curated list editable on
// a portal deploy, with no runner release.
package hostscan

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
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

// PackReq is the per-pack detect signal the suggester matches on, as
// served by the portal's /packs/suggest.json (or derived from a local
// pack.yaml). Binaries are already service-specific — generic helpers are
// stripped upstream — so the runner just asks "is any of this here?".
type PackReq struct {
	ID        string
	Name      string
	OS        []string
	Binaries  []string // service-specific binaries (not generic helpers)
	Processes []string // process names that indicate the service runs
	Ports     []int    // TCP ports that indicate the service listens
}

// MatchesHostOS reports whether this pack's OS allowlist includes the
// current host OS (an empty list matches any OS).
func (r PackReq) MatchesHostOS() bool { return osMatches(r.OS) }

// Facts is what we observed about the host: where each probed binary was
// found, the basenames of running processes, and the set of listening
// TCP ports.
type Facts struct {
	Binaries map[string]string // probed binary name (lowercased) -> path
	Running  map[string]bool   // running process basenames (lowercased)
	Ports    map[int]bool      // listening TCP ports
}

// availableBinary reports whether binary bin is present — running, or on
// $PATH / a standard dir — and a short label for why.
func (f Facts) availableBinary(bin string) (why string, ok bool) {
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
	Evidence []string `json:"evidence"` // e.g. ["nomad (/usr/bin/nomad)", ":3000 (listening)"]
}

// Match returns the packs worth recommending for this host, in stable id
// order. A pack qualifies when its OS matches and ANY of its detect
// signals fires: a service-specific binary is present, a service process
// is running, or a service port is listening. A pack with no detect
// signal at all never matches — there's nothing to recommend it on.
func Match(reqs []PackReq, f Facts) []Suggestion {
	var out []Suggestion
	for _, r := range reqs {
		if !r.MatchesHostOS() {
			continue
		}
		if ev := evidence(r, f); len(ev) > 0 {
			out = append(out, Suggestion{ID: r.ID, Name: r.Name, Evidence: ev})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

// evidence collects a short note for each of the pack's detect signals
// that fires on this host. Empty means nothing matched.
func evidence(r PackReq, f Facts) []string {
	var ev []string
	for _, b := range r.Binaries {
		if why, ok := f.availableBinary(b); ok {
			ev = append(ev, b+" ("+why+")")
		}
	}
	for _, p := range r.Processes {
		if f.Running[strings.ToLower(p)] {
			ev = append(ev, p+" (running)")
		}
	}
	for _, port := range r.Ports {
		if f.Ports[port] {
			ev = append(ev, fmt.Sprintf(":%d (listening)", port))
		}
	}
	return ev
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

// Detect probes the host for the given candidate binary names, the set of
// running processes, and the set of listening ports. binaryNames is the
// union of the catalog's detect binaries — we probe only what some pack
// cares about; processes and ports are scanned wholesale.
func Detect(binaryNames []string) Facts {
	return Facts{
		Binaries: scanBinaries(binaryNames, standardBinDirs),
		Running:  scanProcesses("/proc"),
		Ports:    scanPorts("/proc"),
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

// scanPorts returns the set of TCP ports in the LISTEN state, read from
// <procRoot>/net/tcp and net/tcp6. On a host without /proc (macOS, etc.)
// it returns an empty set.
func scanPorts(procRoot string) map[int]bool {
	out := make(map[int]bool)
	for _, name := range []string{"net/tcp", "net/tcp6"} {
		readListenPorts(filepath.Join(procRoot, name), out)
	}
	return out
}

// readListenPorts parses one /proc/net/tcp{,6} file, adding every
// LISTEN-state local port to out. Lines look like:
//
//	sl  local_address rem_address   st ...
//	 0: 0100007F:1F90 00000000:0000 0A ...
//
// local_address is HEXIP:HEXPORT; st 0A is TCP_LISTEN.
func readListenPorts(path string, out map[int]bool) {
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Scan() // header row
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) < 4 || fields[3] != "0A" {
			continue
		}
		local := fields[1]
		i := strings.LastIndexByte(local, ':')
		if i < 0 {
			continue
		}
		if port, err := strconv.ParseInt(local[i+1:], 16, 32); err == nil {
			out[int(port)] = true
		}
	}
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
