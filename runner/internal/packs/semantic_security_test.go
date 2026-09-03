package packs

import (
	"fmt"
	"strings"
	"testing"
)

func TestLoad_EnforcesSafeShellArgumentChannels(t *testing.T) {
	tests := []struct {
		name      string
		id        string
		args      string
		argv      string
		binary    string
		env       string
		critical  bool
		wantError string
	}{
		{
			name:      "free string in program text",
			id:        "testpack.free_string",
			args:      freeStringArg("pattern"),
			argv:      `argv: ["-c", "grep {{ args.pattern }} /var/log/x"]`,
			wantError: "arg pattern must not be embedded in /bin/sh -c program text",
		},
		{
			name: "regex is not a shell boundary",
			id:   "testpack.pattern_string",
			args: `args:
  - name: pattern
    type: string
    required: true
    validation:
      pattern: "^[a-z]+$"`,
			argv:      `argv: ["-c", "grep {{ args.pattern }} /var/log/x"]`,
			wantError: "arg pattern must not be embedded in /bin/sh -c program text",
		},
		{
			name: "finite string in program text",
			id:   "testpack.enum_string",
			args: finiteStringArg("mode"),
			argv: `argv: ["-c", "scan --mode={{ args.mode }}"]`,
		},
		{
			name: "one-sided numeric bound in program text",
			id:   "testpack.one_sided_integer",
			args: `args:
  - name: count
    type: integer
    required: true
    validation:
      min: 1`,
			argv:      `argv: ["-c", "head -n {{ args.count }} /var/log/x"]`,
			wantError: "arg count must not be embedded in /bin/sh -c program text",
		},
		{
			name: "bounded numeric in program text",
			id:   "testpack.bounded_integer",
			args: boundedIntegerArg("count"),
			argv: `argv: ["-c", "head -n {{ args.count }} /var/log/x"]`,
		},
		{
			name: "free string through env",
			id:   "testpack.env_string",
			args: freeStringArg("pattern"),
			argv: `argv: ["-c", "grep -- \"$PATTERN\" /var/log/x"]`,
			env:  `  env: {PATTERN: "{{ args.pattern }}"}`,
		},
		{
			name: "free string as positional argv",
			id:   "testpack.positional_string",
			args: freeStringArg("pattern"),
			argv: `argv: ["-c", "grep -- \"$1\" /var/log/x", "emisar", "{{ args.pattern }}"]`,
		},
		{
			name:     "critical break-glass action",
			id:       "shell.run_script",
			args:     freeStringArg("script"),
			argv:     `argv: ["-c", "{{ args.script }}"]`,
			critical: true,
		},
		{
			name:      "critical exception needs canonical command boundary",
			id:        "shell.run_script",
			args:      freeStringArg("script"),
			argv:      `argv: ["{{ args.script }}"]`,
			critical:  true,
			wantError: "arg script must not be embedded in /bin/sh shell command selection",
		},
		{
			name:      "noncritical break-glass name",
			id:        "shell.run_script",
			args:      freeStringArg("script"),
			argv:      `argv: ["-c", "{{ args.script }}"]`,
			wantError: "arg script must not be embedded in /bin/sh -c program text",
		},
		{
			name:      "bare bash uses the same boundary",
			id:        "testpack.bash_string",
			binary:    "bash",
			args:      freeStringArg("pattern"),
			argv:      `argv: ["-c", "grep {{ args.pattern }} /var/log/x"]`,
			wantError: "arg pattern must not be embedded in bash -c program text",
		},
		{
			name:      "dynamic shell option cannot select a script",
			id:        "testpack.dynamic_shell_option",
			binary:    "sh",
			args:      freeStringArg("option"),
			argv:      `argv: ["{{ args.option }}", "fixed"]`,
			wantError: "arg option must not be embedded in sh shell command selection",
		},
		{
			name:   "ordinary binary keeps its own c flag",
			id:     "testpack.psql_c",
			binary: "psql",
			args:   freeStringArg("query"),
			argv:   `argv: ["-c", "{{ args.query }}"]`,
		},
		{
			name:   "wrapper finite choice remains authored",
			id:     "testpack.timeout_bounded",
			binary: "timeout",
			args:   boundedIntegerArg("count"),
			argv:   `argv: ["30", "sh", "-c", "head -n {{ args.count }} /var/log/x"]`,
		},
		{
			name:   "static wrapper remains valid",
			id:     "testpack.timeout_static",
			binary: "timeout",
			args:   `args: []`,
			argv:   `argv: ["30", "printf", "%s", "ok"]`,
		},
		{
			name:      "execution path cannot select wrapper child",
			id:        "testpack.timeout_path",
			binary:    "timeout",
			args:      freePathArg("path"),
			argv:      `argv: ["30", "tool"]`,
			env:       `  env: {PATH: "{{ args.path }}"}`,
			wantError: "execution.env PATH must be pack-authored, not args.path",
		},
		{
			name:      "execution shell cannot select wrapper interpreter",
			id:        "testpack.flock_shell",
			binary:    "flock",
			args:      freePathArg("shell"),
			argv:      `argv: ["/tmp/emisar.lock", "-c", "true"]`,
			env:       `  env: {SHELL: "{{ args.shell }}"}`,
			wantError: "execution.env SHELL must be pack-authored, not args.shell",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			assertActionLoad(t, tc.id, tc.binary, tc.args, tc.argv, tc.env, tc.critical, tc.wantError)
		})
	}
}

func TestLoad_ExecWrappersRejectOpenEndedArguments(t *testing.T) {
	wrappers := []string{
		"env", "timeout", "gtimeout", "time", "nice", "ionice", "taskset", "setsid",
		"stdbuf", "nohup", "xargs", "gxargs", "flock", "script", "busybox", "runuser",
		"sudo", "su", "doas", "chroot", "nsenter", "unshare", "setpriv", "systemd-run",
	}
	for _, binary := range wrappers {
		t.Run(binary, func(t *testing.T) {
			assertActionLoad(
				t,
				"testpack."+binary+"_free",
				binary,
				freeStringArg("value"),
				`argv: ["{{ args.value }}"]`,
				"",
				false,
				"arg value must not be passed through "+binary+" command selection",
			)
		})
	}
}

func TestLoad_ExecWrapperControlFormsRejectOpenEndedArguments(t *testing.T) {
	tests := []struct {
		name      string
		binary    string
		args      string
		argv      string
		wantError string
	}{
		{name: "su command", binary: "su", args: freeStringArg("program"), argv: `argv: ["-c", "{{ args.program }}", "root"]`},
		{name: "su session command", binary: "su", args: freeStringArg("program"), argv: `argv: ["--session-command={{ args.program }}", "root"]`},
		{name: "su selected shell", binary: "su", args: freePathArg("shell"), argv: `argv: ["-s", "{{ args.shell }}", "root", "-c", "true"]`},
		{name: "runuser child", binary: "runuser", args: freeStringArg("command"), argv: `argv: ["-u", "root", "--", "{{ args.command }}"]`},
		{name: "nested shell", binary: "timeout", args: freeStringArg("program"), argv: `argv: ["30", "sh", "-c", "{{ args.program }}"]`},
		{name: "sudo environment", binary: "sudo", args: freePathArg("file"), argv: `argv: ["BASH_ENV={{ args.file }}", "bash", "-c", ":"]`},
		{name: "env imported environment", binary: "env", args: freePathArg("file"), argv: `argv: ["--env0-from", "{{ args.file }}", "tool"]`},
		{name: "xargs input file", binary: "xargs", args: freePathArg("file"), argv: `argv: ["-a", "{{ args.file }}", "sh"]`},
		{name: "xargs replacement program", binary: "xargs", args: freeStringArg("program"), argv: `argv: ["-I", "{}", "sh", "-c", "{{ args.program }} {}"]`},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			wantError := tc.wantError
			if wantError == "" {
				wantError = "must not be passed through " + tc.binary + " command selection"
			}
			assertActionLoad(
				t,
				"testpack.wrapper_control",
				tc.binary,
				tc.args,
				tc.argv,
				"",
				false,
				wantError,
			)
		})
	}
}

func TestLoad_CodeInterpretersRejectOpenEndedArguments(t *testing.T) {
	tests := []struct {
		binary string
		argv   string
	}{
		{binary: "python", argv: `argv: ["-Ec", "{{ args.code }}"]`},
		{binary: "python3", argv: `argv: ["-c{{ args.code }}"]`},
		{binary: "python3.13", argv: `argv: ["-c", "{{ args.code }}"]`},
		{binary: "perl", argv: `argv: ["-V:version", "-e", "{{ args.code }}"]`},
		{binary: "perl5.40", argv: `argv: ["-e", "{{ args.code }}"]`},
		{binary: "ruby", argv: `argv: ["--disable=gems", "--eval={{ args.code }}"]`},
		{binary: "node", argv: `argv: ["--require", "fs", "-p{{ args.code }}"]`},
		{binary: "nodejs", argv: `argv: ["-e", "{{ args.code }}"]`},
		{binary: "awk", argv: `argv: ["{{ args.code }}"]`},
		{binary: "gawk", argv: `argv: ["-F", ":", "--source", "{{ args.code }}"]`},
		{binary: "mawk", argv: `argv: ["{{ args.code }}"]`},
		{binary: "php", argv: `argv: ["-nr{{ args.code }}"]`},
		// Recognizing an interpreter is what makes the lint fire at all, so an
		// unlisted one was accepted with no argv inspection whatsoever. A
		// version suffix is the same program (node22, gawk5 used to escape:
		// only python/perl/ruby/php had versioned spellings).
		{binary: "node22", argv: `argv: ["-e", "{{ args.code }}"]`},
		{binary: "gawk5", argv: `argv: ["--source", "{{ args.code }}"]`},
		{binary: "lua", argv: `argv: ["-e", "{{ args.code }}"]`},
		{binary: "lua5.4", argv: `argv: ["-e", "{{ args.code }}"]`},
		{binary: "luajit", argv: `argv: ["-e", "{{ args.code }}"]`},
		{binary: "deno", argv: `argv: ["eval", "{{ args.code }}"]`},
		{binary: "bun", argv: `argv: ["-e", "{{ args.code }}"]`},
		{binary: "Rscript", argv: `argv: ["-e", "{{ args.code }}"]`},
		{binary: "tclsh", argv: `argv: ["{{ args.code }}"]`},
		{binary: "wish", argv: `argv: ["{{ args.code }}"]`},
		{binary: "pwsh", argv: `argv: ["-Command", "{{ args.code }}"]`},
		{binary: "powershell", argv: `argv: ["-Command", "{{ args.code }}"]`},
		{binary: "osascript", argv: `argv: ["-e", "{{ args.code }}"]`},
	}
	for _, tc := range tests {
		t.Run(tc.binary, func(t *testing.T) {
			assertActionLoad(
				t,
				"testpack."+strings.ToLower(strings.NewReplacer(".", "_", "/", "_").Replace(tc.binary))+"_code",
				tc.binary,
				freeStringArg("code"),
				tc.argv,
				"",
				false,
				"arg code must not be passed through "+tc.binary,
			)
		})
	}
}

func TestLoad_ShellAliasesRejectOpenEndedPrograms(t *testing.T) {
	for _, binary := range []string{"fish", "csh", "tcsh", "hush"} {
		t.Run(binary, func(t *testing.T) {
			assertActionLoad(
				t,
				"testpack."+strings.ToLower(binary)+"_code",
				binary,
				freeStringArg("code"),
				`argv: ["-c", "{{ args.code }}"]`,
				"",
				false,
				"arg code must not be embedded in "+binary+" -c program text",
			)
		})
	}
}

func TestLoad_CodeInterpreterAcceptsFiniteArguments(t *testing.T) {
	assertActionLoad(
		t,
		"testpack.python_mode",
		"python3",
		finiteStringArg("mode"),
		`argv: ["-c", "print('{{ args.mode }}')"]`,
		"",
		false,
		"",
	)
}

func TestLoad_ScriptKindKeepsFreeStringsInArgv(t *testing.T) {
	action := strings.Replace(actionYAML("testpack.script_argv"), "kind: exec", "kind: script", 1)
	action = strings.Replace(action, "args: []", freeStringArg("pattern"), 1)
	action = strings.Replace(action, `  command:
    binary: echo
    argv: ["hi"]`, `  script:
    path: scripts/run.sh
    interpreter: /bin/sh
  argv: ["{{ args.pattern }}"]`, 1)

	root := writePack(t, t.TempDir(), "p", map[string]string{
		"pack.yaml":      packYAML("testpack"),
		"actions/a.yaml": action,
		"scripts/run.sh": "#!/bin/sh\nprintf '%s\\n' \"$1\"\n",
	})
	if _, err := LoadOne(root, LoadOptions{}); err != nil {
		t.Fatalf("LoadOne() rejected script argv data channel: %v", err)
	}
}

func TestLoad_ScriptKindRejectsCommandWrapperInterpreter(t *testing.T) {
	action := strings.Replace(actionYAML("testpack.script_wrapper"), "kind: exec", "kind: script", 1)
	action = strings.Replace(action, "args: []", freeStringArg("command"), 1)
	action = strings.Replace(action, `  command:
    binary: echo
    argv: ["hi"]`, `  script:
    path: scripts/run.sh
    interpreter: flock
  argv: ["{{ args.command }}"]`, 1)

	root := writePack(t, t.TempDir(), "p", map[string]string{
		"pack.yaml":      packYAML("testpack"),
		"actions/a.yaml": action,
		"scripts/run.sh": "#!/bin/sh\nprintf '%s\\n' \"$1\"\n",
	})
	_, err := LoadOne(root, LoadOptions{})
	want := "execution.script.interpreter flock is a command wrapper, not a script interpreter"
	if err == nil || !strings.Contains(err.Error(), want) {
		t.Fatalf("LoadOne() error = %v, want containing %q", err, want)
	}
}

func TestLoad_ScriptKindRejectsDynamicCommandSearchEnvironment(t *testing.T) {
	for index, name := range []string{"PATH", "SHELL", "PYTHONPATH", "ZDOTDIR"} {
		t.Run(name, func(t *testing.T) {
			action := strings.Replace(actionYAML("testpack.script_environment"), "kind: exec", "kind: script", 1)
			action = strings.Replace(action, "args: []", freePathArg("value"), 1)
			interpreter := "    interpreter: /bin/sh\n"
			if index == 0 {
				interpreter = ""
			}
			action = strings.Replace(action, `  command:
    binary: echo
    argv: ["hi"]`, fmt.Sprintf(`  script:
    path: scripts/run.sh
%s  argv: []
  env: {%s: "{{ args.value }}"}`, interpreter, name), 1)

			root := writePack(t, t.TempDir(), "p", map[string]string{
				"pack.yaml":      packYAML("testpack"),
				"actions/a.yaml": action,
				"scripts/run.sh": "#!/bin/sh\ntool\n",
			})
			_, err := LoadOne(root, LoadOptions{})
			want := "execution.env " + name + " must be pack-authored, not args.value"
			if err == nil || !strings.Contains(err.Error(), want) {
				t.Fatalf("LoadOne() error = %v, want containing %q", err, want)
			}
		})
	}
}

func TestLoad_DirectInterpretersRejectDynamicModuleSearchEnvironment(t *testing.T) {
	tests := []struct {
		binary string
		name   string
	}{
		{binary: "python3", name: "PYTHONPATH"},
		{binary: "python3", name: "PYTHONUSERBASE"},
		{binary: "perl", name: "PERL5LIB"},
		{binary: "ruby", name: "RUBYLIB"},
		{binary: "ruby", name: "RUBYGEMS_GEMDEPS"},
		{binary: "node", name: "NODE_PATH"},
		{binary: "zsh", name: "ZDOTDIR"},
		{binary: "zsh", name: "HOME"},
		{binary: "gawk", name: "AWKPATH"},
		{binary: "php", name: "PHPRC"},
		// GEM_HOME/GEM_PATH point ruby at a gem tree the caller controls —
		// the same "select the code I load" shape as RUBYLIB, and not covered
		// by actionspec's exact-name hijack list either.
		{binary: "ruby", name: "GEM_HOME"},
		{binary: "ruby", name: "GEM_PATH"},
		{binary: "lua", name: "LUA_INIT"},
		{binary: "Rscript", name: "R_PROFILE"},
		{binary: "tclsh", name: "TCLLIBPATH"},
		{binary: "pwsh", name: "PSModulePath"},
	}
	for _, tc := range tests {
		t.Run(tc.binary+"_"+tc.name, func(t *testing.T) {
			assertActionLoad(
				t,
				"testpack.dynamic_module_path",
				tc.binary,
				freePathArg("value"),
				`argv: ["-c", "true"]`,
				fmt.Sprintf(`  env: {%s: "{{ args.value }}"}`, tc.name),
				false,
				"execution.env "+tc.name+" must be pack-authored, not args.value",
			)
		})
	}
}

func TestLoad_StaticRuntimeWrapperInputsRemainPackAuthored(t *testing.T) {
	tests := []struct {
		name   string
		binary string
		argv   string
	}{
		{name: "xargs input", binary: "xargs", argv: `argv: ["-a", "/fixed/input", "printf", "%s"]`},
		{name: "env imported environment", binary: "env", argv: `argv: ["--env0-from=/fixed/environment", "tool"]`},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			assertActionLoad(t, "testpack.static_runtime_input", tc.binary, `args: []`, tc.argv, "", false, "")
		})
	}
}

func TestLoad_OrdinaryBinaryKeepsApplicationEnvironment(t *testing.T) {
	assertActionLoad(
		t,
		"testpack.application_environment",
		"psql",
		freeStringArg("environment"),
		`argv: ["--version"]`,
		`  env: {ENV: "{{ args.environment }}"}`,
		false,
		"",
	)
}

func assertActionLoad(
	t *testing.T,
	id string,
	binary string,
	args string,
	argv string,
	env string,
	critical bool,
	wantError string,
) {
	t.Helper()
	action := actionYAML(id)
	action = strings.Replace(action, "args: []", args, 1)
	if binary == "" {
		binary = "/bin/sh"
	}
	action = strings.Replace(action, "binary: echo", "binary: "+binary, 1)
	action = strings.Replace(action, `argv: ["hi"]`, argv, 1)
	if env != "" {
		action = strings.Replace(action, "  timeout: 5s", env+"\n  timeout: 5s", 1)
	}
	if critical {
		action = strings.Replace(action, "risk: low", "risk: critical", 1)
	}

	root := writePack(t, t.TempDir(), "p", map[string]string{
		"pack.yaml":      packYAML("testpack"),
		"actions/a.yaml": action,
	})
	_, err := LoadOne(root, LoadOptions{})
	if wantError == "" {
		if err != nil {
			t.Fatalf("LoadOne() rejected safe action: %v", err)
		}
		return
	}
	if err == nil || !strings.Contains(err.Error(), wantError) {
		t.Fatalf("LoadOne() error = %v, want containing %q", err, wantError)
	}
}

func freeStringArg(name string) string {
	return fmt.Sprintf(`args:
  - name: %s
    type: string
    required: true`, name)
}

func freePathArg(name string) string {
	return fmt.Sprintf(`args:
  - name: %s
    type: path
    required: true`, name)
}

func finiteStringArg(name string) string {
	return fmt.Sprintf(`args:
  - name: %s
    type: string
    required: true
    validation:
      enum: [fast, thorough]`, name)
}

func boundedIntegerArg(name string) string {
	return fmt.Sprintf(`args:
  - name: %s
    type: integer
    required: true
    validation:
      min: 1
      max: 100`, name)
}
