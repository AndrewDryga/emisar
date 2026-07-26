package packs

import (
	"strings"
	"testing"
)

func TestLoad_EnforcesSafeShellArgumentChannels(t *testing.T) {
	tests := []struct {
		name      string
		id        string
		args      string
		argv      string
		env       string
		critical  bool
		wantError string
	}{
		{
			name: "free string in program text",
			id:   "testpack.free_string",
			args: `args:
  - name: pattern
    type: string
    required: true`,
			argv:      `argv: ["-c", "grep {{ args.pattern }} /var/log/x"]`,
			wantError: "arg pattern must not be embedded in /bin/sh -c program text",
		},
		{
			name: "regex-constrained string in program text",
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
			name: "free path in program text",
			id:   "testpack.free_path",
			args: `args:
  - name: file
    type: path
    required: true`,
			argv:      `argv: ["-c", "tail {{ args.file }}"]`,
			wantError: "arg file must not be embedded in /bin/sh -c program text",
		},
		{
			name: "finite string in program text",
			id:   "testpack.enum_string",
			args: `args:
  - name: mode
    type: string
    required: true
    validation:
      enum: [fast, thorough]`,
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
			args: `args:
  - name: count
    type: integer
    required: true
    validation:
      min: 1
      max: 100`,
			argv: `argv: ["-c", "head -n {{ args.count }} /var/log/x"]`,
		},
		{
			name: "free string through env",
			id:   "testpack.env_string",
			args: `args:
  - name: pattern
    type: string
    required: true`,
			argv: `argv: ["-c", "grep -- \"$PATTERN\" /var/log/x"]`,
			env:  `  env: {PATTERN: "{{ args.pattern }}"}`,
		},
		{
			name: "free string as positional argv",
			id:   "testpack.positional_string",
			args: `args:
  - name: pattern
    type: string
    required: true`,
			argv: `argv: ["-c", "grep -- \"$1\" /var/log/x", "emisar", "{{ args.pattern }}"]`,
		},
		{
			name: "critical break-glass action",
			id:   "shell.run_script",
			args: `args:
  - name: script
    type: string
    required: true`,
			argv:     `argv: ["-c", "{{ args.script }}"]`,
			critical: true,
		},
		{
			name: "noncritical break-glass name",
			id:   "shell.run_script",
			args: `args:
  - name: script
    type: string
    required: true`,
			argv:      `argv: ["-c", "{{ args.script }}"]`,
			wantError: "arg script must not be embedded in /bin/sh -c program text",
		},
		{
			name: "critical ordinary action",
			id:   "testpack.critical_string",
			args: `args:
  - name: script
    type: string
    required: true`,
			argv:      `argv: ["-c", "{{ args.script }}"]`,
			critical:  true,
			wantError: "arg script must not be embedded in /bin/sh -c program text",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			action := actionYAML(tc.id)
			action = strings.Replace(action, "args: []", tc.args, 1)
			action = strings.Replace(action, "binary: echo", "binary: /bin/sh", 1)
			action = strings.Replace(action, `argv: ["hi"]`, tc.argv, 1)
			if tc.env != "" {
				action = strings.Replace(action, "  timeout: 5s", tc.env+"\n  timeout: 5s", 1)
			}
			if tc.critical {
				action = strings.Replace(action, "risk: low", "risk: critical", 1)
			}

			root := writePack(t, t.TempDir(), "p", map[string]string{
				"pack.yaml":      packYAML("testpack"),
				"actions/a.yaml": action,
			})
			_, err := LoadOne(root, LoadOptions{})
			if tc.wantError == "" {
				if err != nil {
					t.Fatalf("LoadOne() rejected safe shell argument channel: %v", err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tc.wantError) {
				t.Fatalf("LoadOne() error = %v, want containing %q", err, tc.wantError)
			}
		})
	}
}

func TestLoad_ScriptKindKeepsFreeStringsInArgv(t *testing.T) {
	action := strings.Replace(actionYAML("testpack.script_argv"), "kind: exec", "kind: script", 1)
	action = strings.Replace(action, "args: []", `args:
  - name: pattern
    type: string
    required: true`, 1)
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
