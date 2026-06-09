package executor

import (
	"testing"
	"time"

	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

func TestPlanForExec(t *testing.T) {
	lim := Limits{Timeout: 2 * time.Second, MaxStdoutBytes: 100, MaxStderrBytes: 50}
	// Execution.Command is a pointer the loader always sets for exec-kind
	// actions; PlanForExec dereferences it, so the test must too.
	a := &actionspec.Action{}
	a.Execution.Command = &actionspec.Command{Binary: "/bin/echo"}
	a.Execution.User = "nobody"

	// CWD unset → defaults to "/", never the runner's own working dir.
	p := PlanForExec(a, []string{"hi"}, map[string]string{"K": "V"}, lim)
	if p.Binary != "/bin/echo" {
		t.Errorf("binary=%q", p.Binary)
	}
	if len(p.Argv) != 1 || p.Argv[0] != "hi" {
		t.Errorf("argv=%v", p.Argv)
	}
	if p.CWD != "/" {
		t.Errorf("cwd should default to /, got %q", p.CWD)
	}
	if p.Env["K"] != "V" {
		t.Errorf("env not mapped: %v", p.Env)
	}
	if p.User != "nobody" {
		t.Errorf("user=%q", p.User)
	}
	if p.Limits != lim {
		t.Errorf("limits not copied: %+v", p.Limits)
	}

	// An explicit CWD is honoured.
	a.Execution.CWD = "/work"
	if got := PlanForExec(a, nil, nil, lim); got.CWD != "/work" {
		t.Errorf("explicit cwd=%q", got.CWD)
	}
}

func TestPlanForScript(t *testing.T) {
	lim := Limits{Timeout: time.Second, MaxStdoutBytes: 10, MaxStderrBytes: 10}
	// Execution.Script is a pointer the loader always sets for script-kind
	// actions; PlanForScript dereferences it for the interpreter.
	a := &actionspec.Action{}
	a.Execution.Script = &actionspec.Script{}
	a.Execution.User = "svc"

	// No interpreter → defaults to /bin/sh; the script path is argv[0], with
	// rendered args following.
	p := PlanForScript(a, "/packs/p/scripts/run.sh", "deadbeef", []string{"--flag"}, nil, lim)
	if p.Binary != "/bin/sh" {
		t.Errorf("default interpreter, got %q", p.Binary)
	}
	if len(p.Argv) != 2 || p.Argv[0] != "/packs/p/scripts/run.sh" || p.Argv[1] != "--flag" {
		t.Errorf("argv=%v", p.Argv)
	}
	if p.ScriptSHA256 != "deadbeef" {
		t.Errorf("scriptSHA=%q", p.ScriptSHA256)
	}
	if p.CWD != "/" {
		t.Errorf("cwd should default to /, got %q", p.CWD)
	}
	if p.User != "svc" {
		t.Errorf("user=%q", p.User)
	}

	// An explicit interpreter is honoured and the script stays argv[0].
	a.Execution.Script.Interpreter = "/usr/bin/python3"
	got := PlanForScript(a, "/s.py", "", nil, nil, lim)
	if got.Binary != "/usr/bin/python3" {
		t.Errorf("interp=%q", got.Binary)
	}
	if len(got.Argv) != 1 || got.Argv[0] != "/s.py" {
		t.Errorf("argv=%v", got.Argv)
	}
}
