package actionspec

import (
	"strings"
	"testing"
	"time"
)

func TestValidActionID(t *testing.T) {
	cases := []struct {
		id   string
		want bool
	}{
		// Valid: two-segment namespaced ids.
		{"linux.uptime", true},
		{"cassandra.nodetool_status", true},
		{"myorg.cassandra.nodetool_repair", true},
		{"a.b", true},
		{"acme-corp.do-thing", true},
		{"ns_1.action_2", true},

		// Invalid.
		{"", false},
		{"unprefixed", false},
		{".bad", false},
		{"bad.", false},
		{"bad..segment", false},
		{"Capital.case", false},
		{"1starts.with.digit", false},
		{"has space.x", false},
		{"weird-#.x", false},
		{strings.Repeat("a", 130) + ".x", false}, // length cap
	}
	for _, c := range cases {
		got := validActionID(c.id)
		if got != c.want {
			t.Errorf("validActionID(%q) = %v, want %v", c.id, got, c.want)
		}
	}
}

func TestValidIDSegment(t *testing.T) {
	cases := []struct {
		seg  string
		want bool
	}{
		{"abc", true},
		{"a", true},
		{"a_b", true},
		{"a-b", true},
		{"a1", true},
		{"", false},
		{"1a", false},  // can't start with digit
		{"_a", false},  // can't start with underscore
		{"-a", false},  // can't start with hyphen
		{"A", false},   // no uppercase
		{"a b", false}, // no spaces
		{"a.b", false}, // dots aren't part of a segment
	}
	for _, c := range cases {
		got := validIDSegment(c.seg)
		if got != c.want {
			t.Errorf("validIDSegment(%q) = %v, want %v", c.seg, got, c.want)
		}
	}
}

func TestValidateTimeoutBounds(t *testing.T) {
	mk := func(def, lo, hi time.Duration) *Action {
		return &Action{
			ID: "p.a",
			Execution: Execution{
				Timeout:    Duration(def),
				TimeoutMin: Duration(lo),
				TimeoutMax: Duration(hi),
			},
		}
	}
	// Defaults — min/max unset means pin to default.
	if err := validateTimeoutBounds(mk(5*time.Second, 0, 0)); err != nil {
		t.Fatalf("unset bounds should pass: %v", err)
	}
	// All equal — pinning allowed.
	if err := validateTimeoutBounds(mk(5*time.Second, 5*time.Second, 5*time.Second)); err != nil {
		t.Fatalf("equal bounds should pass: %v", err)
	}
	// In range.
	if err := validateTimeoutBounds(mk(5*time.Second, 1*time.Second, 10*time.Second)); err != nil {
		t.Fatalf("in range should pass: %v", err)
	}
	// Below min.
	if err := validateTimeoutBounds(mk(500*time.Millisecond, 1*time.Second, 10*time.Second)); err == nil {
		t.Fatal("default below min should fail")
	}
	// Above max.
	if err := validateTimeoutBounds(mk(20*time.Second, 1*time.Second, 10*time.Second)); err == nil {
		t.Fatal("default above max should fail")
	}
	// Min > max.
	if err := validateTimeoutBounds(mk(5*time.Second, 10*time.Second, 1*time.Second)); err == nil {
		t.Fatal("min > max should fail")
	}
}

func TestValidateOutputBounds(t *testing.T) {
	mk := func(def, lo, hi int) *Action {
		a := &Action{ID: "p.a"}
		a.Output.MaxStdoutBytes = def
		a.Output.MaxStdoutBytesMin = lo
		a.Output.MaxStdoutBytesMax = hi
		a.Output.MaxStderrBytes = 1024 // stderr always valid
		return a
	}
	if err := validateOutputBounds(mk(1024, 0, 0)); err != nil {
		t.Fatalf("unset bounds should pass: %v", err)
	}
	if err := validateOutputBounds(mk(1024, 512, 4096)); err != nil {
		t.Fatalf("in range should pass: %v", err)
	}
	if err := validateOutputBounds(mk(256, 1024, 4096)); err == nil {
		t.Fatal("below min should fail")
	}
	if err := validateOutputBounds(mk(8192, 1024, 4096)); err == nil {
		t.Fatal("above max should fail")
	}
	if err := validateOutputBounds(mk(1024, 4096, 1024)); err == nil {
		t.Fatal("min > max should fail")
	}
}

func TestValidateSuccessExitCodes(t *testing.T) {
	mk := func(codes ...int) *Action {
		return &Action{ID: "p.a", Execution: Execution{SuccessExitCodes: codes}}
	}
	// Empty/unset is fine — the common case.
	if err := validateSuccessExitCodes(mk()); err != nil {
		t.Fatalf("no codes should pass: %v", err)
	}
	// Valid non-zero codes (single + multiple, full 1..255 range).
	if err := validateSuccessExitCodes(mk(21)); err != nil {
		t.Fatalf("21 should pass: %v", err)
	}
	if err := validateSuccessExitCodes(mk(1, 21, 255)); err != nil {
		t.Fatalf("1,21,255 should pass: %v", err)
	}
	// 0 is always success — listing it is a mistake.
	if err := validateSuccessExitCodes(mk(0)); err == nil {
		t.Fatal("0 should fail (always success)")
	}
	// Out of range — a process can't return these.
	if err := validateSuccessExitCodes(mk(256)); err == nil {
		t.Fatal("256 should fail (out of range)")
	}
	if err := validateSuccessExitCodes(mk(-1)); err == nil {
		t.Fatal("-1 should fail (out of range)")
	}
	// Duplicates are a typo, not intent.
	if err := validateSuccessExitCodes(mk(21, 21)); err == nil {
		t.Fatal("duplicate 21 should fail")
	}
}

func TestParseExtendedDuration(t *testing.T) {
	cases := []struct {
		in      string
		want    time.Duration
		wantErr bool
	}{
		{"30s", 30 * time.Second, false},
		{"5m", 5 * time.Minute, false},
		{"2h", 2 * time.Hour, false},
		{"7d", 7 * 24 * time.Hour, false},
		{"2w", 14 * 24 * time.Hour, false},
		// Mixed like "1d12h" falls back to stdlib parser, which rejects.
		{"1d12h", 0, true},
		{"banana", 0, true},
		{"", 0, false}, // UnmarshalYAML handles this case; parser sees empty → stdlib errors
	}
	for _, c := range cases {
		got, err := parseExtendedDuration(c.in)
		if c.in == "" {
			// Empty input is rejected by stdlib but our YAML unmarshaler
			// handles it earlier. We don't exercise that here.
			continue
		}
		if c.wantErr {
			if err == nil {
				t.Errorf("parseExtendedDuration(%q) should fail", c.in)
			}
			continue
		}
		if err != nil {
			t.Errorf("parseExtendedDuration(%q): %v", c.in, err)
			continue
		}
		if got != c.want {
			t.Errorf("parseExtendedDuration(%q) = %v, want %v", c.in, got, c.want)
		}
	}
}

func TestRedactionRule_Validate(t *testing.T) {
	cases := []struct {
		name string
		rule RedactionRule
		ok   bool
	}{
		{"missing name", RedactionRule{Type: "regex", Pattern: "x"}, false},
		{"regex missing pattern", RedactionRule{Name: "r", Type: "regex"}, false},
		{"literal missing literal", RedactionRule{Name: "r", Type: "literal"}, false},
		{"unknown type", RedactionRule{Name: "r", Type: "regexp", Pattern: "x"}, false},
		{"empty type", RedactionRule{Name: "r"}, false},
		{"valid regex", RedactionRule{Name: "r", Type: "regex", Pattern: "x"}, true},
		{"valid literal", RedactionRule{Name: "r", Type: "literal", Literal: "x"}, true},
		// An uncompilable redaction pattern must fail at load (fail closed) —
		// otherwise the combined redactor silently drops the rule at runtime.
		{"uncompilable regex", RedactionRule{Name: "r", Type: "regex", Pattern: "(unclosed"}, false},
		{"oversized repeat", RedactionRule{Name: "r", Type: "regex", Pattern: ".{0,2048}"}, false},
	}
	for _, c := range cases {
		err := c.rule.Validate()
		if c.ok && err != nil {
			t.Errorf("%s: should pass, got %v", c.name, err)
		}
		if !c.ok && err == nil {
			t.Errorf("%s: should fail", c.name)
		}
	}
}

func TestArg_Validate_PatternRequiresStringType(t *testing.T) {
	pat := &Validation{Pattern: "^[a-z]+$"}

	for _, ty := range []ArgType{ArgString, ArgPath} {
		if err := (Arg{Name: "a", Type: ty, Validation: pat}).Validate(); err != nil {
			t.Errorf("pattern on %s should be valid: %v", ty, err)
		}
	}

	// On a non-string arg the pattern can never match, so the action would
	// load yet be permanently unrunnable — reject it at load.
	for _, ty := range []ArgType{ArgInteger, ArgNumber, ArgBoolean, ArgStringArray, ArgIntegerArray} {
		if err := (Arg{Name: "a", Type: ty, Validation: pat}).Validate(); err == nil {
			t.Errorf("pattern on %s should be rejected at load", ty)
		}
	}

	if err := (Arg{Name: "a", Type: ArgString, Validation: &Validation{Pattern: "(bad"}}).Validate(); err == nil {
		t.Error("uncompilable pattern should still be rejected")
	}
}

func TestArg_Validate_MaxLength(t *testing.T) {
	ptr := func(n int) *int { return &n }

	// Valid on string-ish types.
	for _, ty := range []ArgType{ArgString, ArgPath, ArgStringArray} {
		if err := (Arg{Name: "a", Type: ty, Validation: &Validation{MaxLength: ptr(64)}}).Validate(); err != nil {
			t.Errorf("max_length on %s should be valid: %v", ty, err)
		}
	}

	// Rejected on types where the runtime validator can't apply it.
	for _, ty := range []ArgType{ArgInteger, ArgNumber, ArgBoolean, ArgDuration, ArgIntegerArray} {
		if err := (Arg{Name: "a", Type: ty, Validation: &Validation{MaxLength: ptr(64)}}).Validate(); err == nil {
			t.Errorf("max_length on %s should be rejected at load", ty)
		}
	}

	// Non-positive caps are a schema bug.
	for _, n := range []int{0, -1} {
		if err := (Arg{Name: "a", Type: ArgString, Validation: &Validation{MaxLength: ptr(n)}}).Validate(); err == nil {
			t.Errorf("max_length %d should be rejected", n)
		}
	}
}

func TestAction_Validate(t *testing.T) {
	good := func() *Action {
		return &Action{
			SchemaVersion: 1,
			ID:            "t.echo",
			Title:         "Echo",
			Kind:          KindExec,
			Risk:          RiskLow,
			Description:   "describes what this does",
			SideEffects:   []string{"none"},
			Execution: Execution{
				Command: &Command{Binary: "/bin/echo", Argv: []string{"hi"}},
				Timeout: Duration(5 * time.Second),
			},
			Output: Output{
				Parser:         ParserText,
				MaxStdoutBytes: 1024,
				MaxStderrBytes: 1024,
			},
		}
	}

	if err := good().Validate(); err != nil {
		t.Fatalf("good action should validate: %v", err)
	}

	cases := []struct {
		name    string
		mut     func(*Action)
		wantSub string
	}{
		{"wrong schema", func(a *Action) { a.SchemaVersion = 2 }, "schema_version"},
		{"empty id", func(a *Action) { a.ID = "" }, "missing id"},
		{"invalid id", func(a *Action) { a.ID = "noNamespace" }, "invalid id"},
		{"missing title", func(a *Action) { a.Title = "" }, "missing title"},
		{"long title", func(a *Action) { a.Title = strings.Repeat("a", 161) }, "160 bytes"},
		{"long summary", func(a *Action) { a.Summary = strings.Repeat("a", 513) }, "512 bytes"},
		{"bidi description", func(a *Action) { a.Description = "status \u202erof" }, "U+202E"},
		{"control side effect", func(a *Action) { a.SideEffects = []string{"writes\x00disk"} }, "U+0000"},
		{"long side effect", func(a *Action) { a.SideEffects = []string{strings.Repeat("a", 1025)} }, "1024 bytes"},
		{"too many side effects", func(a *Action) {
			a.SideEffects = make([]string, 17)
			for i := range a.SideEffects {
				a.SideEffects[i] = "effect"
			}
		}, "limit is 16"},
		{"blank example title", func(a *Action) {
			a.Examples = []Example{{Title: "  ", Args: map[string]any{}}}
		}, "example title"},
		{"too many examples", func(a *Action) {
			a.Examples = make([]Example, 17)
			for i := range a.Examples {
				a.Examples[i] = Example{Title: "example", Args: map[string]any{}}
			}
		}, "limit is 16"},
		{"invalid kind", func(a *Action) { a.Kind = "bogus" }, "invalid kind"},
		{"invalid risk", func(a *Action) { a.Risk = "nope" }, "invalid risk"},
		{"empty description", func(a *Action) { a.Description = "" }, "missing description"},
		{"empty side_effects", func(a *Action) { a.SideEffects = nil }, "side_effects"},
		{"zero timeout", func(a *Action) { a.Execution.Timeout = 0 }, "timeout"},
		{"zero stdout limit", func(a *Action) { a.Output.MaxStdoutBytes = 0 }, "max_stdout_bytes"},
		{"zero stderr limit", func(a *Action) { a.Output.MaxStderrBytes = 0 }, "max_stderr_bytes"},
		{"exec missing command", func(a *Action) { a.Execution.Command = nil }, "execution.command"},
		{"exec empty binary", func(a *Action) { a.Execution.Command.Binary = "" }, "binary"},
		{"exec with script set", func(a *Action) {
			a.Execution.Script = &Script{Path: "x.sh", Interpreter: "/bin/sh"}
		}, "must not set execution.script"},
		{"script missing script", func(a *Action) {
			a.Kind = KindScript
			a.Execution.Command = nil
		}, "execution.script"},
		{"duplicate arg", func(a *Action) {
			a.Args = []Arg{
				{Name: "x", Type: ArgString},
				{Name: "x", Type: ArgString},
			}
		}, "duplicate"},
		{"reserved arg reason", func(a *Action) {
			a.Args = []Arg{{Name: "reason", Type: ArgString}}
		}, "reserved control-plane field"},
		{"reserved arg runner", func(a *Action) {
			a.Args = []Arg{{Name: "runner", Type: ArgString}}
		}, "reserved control-plane field"},
		{"reserved arg runners", func(a *Action) {
			a.Args = []Arg{{Name: "runners", Type: ArgStringArray}}
		}, "reserved control-plane field"},
		{"reserved arg idempotency_key", func(a *Action) {
			a.Args = []Arg{{Name: "idempotency_key", Type: ArgString}}
		}, "reserved control-plane field"},
		{"reserved arg wait", func(a *Action) {
			a.Args = []Arg{{Name: "wait", Type: ArgString}}
		}, "reserved control-plane field"},
		{"reserved arg action_id", func(a *Action) {
			a.Args = []Arg{{Name: "action_id", Type: ArgString}}
		}, "reserved control-plane field"},
		{"reserved arg attestation", func(a *Action) {
			a.Args = []Arg{{Name: "attestation", Type: ArgString}}
		}, "reserved control-plane field"},
		{"bad redaction rule", func(a *Action) {
			a.Output.Redact = []RedactionRule{{Name: "r", Type: "nope"}}
		}, "redaction"},
		{"env LD_PRELOAD", func(a *Action) {
			a.Execution.Env = map[string]string{"LD_PRELOAD": "/tmp/evil.so"}
		}, "hijack"},
		{"env LD_LIBRARY_PATH", func(a *Action) {
			a.Execution.Env = map[string]string{"LD_LIBRARY_PATH": "/tmp"}
		}, "hijack"},
		{"env DYLD_INSERT_LIBRARIES", func(a *Action) {
			a.Execution.Env = map[string]string{"DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib"}
		}, "hijack"},
		{"env BASH_ENV", func(a *Action) {
			a.Execution.Env = map[string]string{"BASH_ENV": "/tmp/evil.sh"}
		}, "hijack"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			a := good()
			c.mut(a)
			err := a.Validate()
			if err == nil {
				t.Fatalf("expected validation failure")
			}
			if !strings.Contains(err.Error(), c.wantSub) {
				t.Fatalf("error %q should contain %q", err, c.wantSub)
			}
		})
	}

	// A normal arg name — including `note`, the rename target packs use in
	// place of a colliding `reason` — must still validate.
	t.Run("non-reserved arg allowed", func(t *testing.T) {
		a := good()
		a.Args = []Arg{{Name: "note", Type: ArgString}}
		if err := a.Validate(); err != nil {
			t.Fatalf("non-reserved arg should validate, got %v", err)
		}
	})

	// The env denylist must target only loader/shell-init hijack vectors,
	// not ordinary configuration — a benign env key (incl. ENV, which is
	// deliberately not denied) still validates.
	t.Run("benign env allowed", func(t *testing.T) {
		a := good()
		a.Execution.Env = map[string]string{"PGHOST": "db.internal", "ENV": "production"}
		if err := a.Validate(); err != nil {
			t.Fatalf("benign env keys should validate, got %v", err)
		}
	})
}

func TestArg_Validate(t *testing.T) {
	cases := []struct {
		name string
		arg  Arg
		ok   bool
	}{
		{"empty name", Arg{Type: ArgString}, false},
		{"invalid type", Arg{Name: "x", Type: "weird"}, false},
		{"required with default", Arg{Name: "x", Type: ArgString, Required: true, Default: "y"}, false},
		{"valid", Arg{Name: "x", Type: ArgString}, true},
		{"valid with default", Arg{Name: "x", Type: ArgString, Default: "y"}, true},
		{"valid pattern", Arg{Name: "x", Type: ArgString, Validation: &Validation{Pattern: "^.{0,1000}$"}}, true},
		// Go caps a repeat bound at 1000; a larger one compiles fine in YAML
		// but is rejected by regexp.Compile, so the action could never run.
		{"oversized repeat pattern", Arg{Name: "x", Type: ArgString, Validation: &Validation{Pattern: "^.{0,2048}$"}}, false},
		{"malformed pattern", Arg{Name: "x", Type: ArgString, Validation: &Validation{Pattern: "^[a-z"}}, false},
	}
	for _, c := range cases {
		err := c.arg.Validate()
		if c.ok && err != nil {
			t.Errorf("%s: should pass, got %v", c.name, err)
		}
		if !c.ok && err == nil {
			t.Errorf("%s: should fail", c.name)
		}
	}
}

func TestArgType_Valid(t *testing.T) {
	valid := []ArgType{
		ArgString, ArgInteger, ArgNumber, ArgBoolean,
		ArgDuration, ArgPath, ArgStringArray, ArgIntegerArray,
	}
	for _, t_ := range valid {
		if !t_.Valid() {
			t.Errorf("%s should be valid", t_)
		}
	}
	if ArgType("nope").Valid() {
		t.Error("nope should be invalid")
	}
}

func TestKind_Valid(t *testing.T) {
	if !KindExec.Valid() || !KindScript.Valid() {
		t.Fatal("kinds should be valid")
	}
	if Kind("nope").Valid() {
		t.Fatal("nope should be invalid")
	}
}

func TestParser_Valid(t *testing.T) {
	if !ParserText.Valid() || !ParserJSON.Valid() || !Parser("").Valid() {
		t.Fatal("expected parsers should be valid (including empty)")
	}
	if Parser("xml").Valid() {
		t.Fatal("xml should be invalid")
	}
}

func TestRiskOrdering(t *testing.T) {
	if !RiskLow.LessOrEqual(RiskHigh) {
		t.Error("low <= high")
	}
	if !RiskMedium.LessOrEqual(RiskHigh) {
		t.Error("medium <= high")
	}
	if RiskCritical.LessOrEqual(RiskMedium) {
		t.Error("critical !<= medium")
	}
	if RiskHigh.LessOrEqual(RiskLow) {
		t.Error("high !<= low")
	}
	// Invalid values rank as -1.
	if Risk("nope").Rank() != -1 {
		t.Error("invalid risk should rank -1")
	}
	if Risk("nope").LessOrEqual(RiskLow) {
		t.Error("invalid risk should not be <= anything")
	}
}

func TestSecretArgWarnings(t *testing.T) {
	a := &Action{
		ID: "x.y",
		Args: []Arg{
			{Name: "api_key", Type: "string"},                     // secret-ish, unmarked → warn
			{Name: "auth_token", Type: "string", Sensitive: true}, // secret-ish but marked → no warn
			{Name: "lines", Type: "integer"},                      // not secret-ish → no warn
		},
	}

	w := a.SecretArgWarnings()
	if len(w) != 1 {
		t.Fatalf("want 1 warning, got %d: %v", len(w), w)
	}
	if !strings.Contains(w[0], "api_key") {
		t.Fatalf("warning should name the offending arg: %v", w)
	}
}
