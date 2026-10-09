package devtool

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// Native behavior cases prove kernel-held scalar/range/inverse sets. These
// supplemental representations exercise conservative unknown/alias handling
// in the exact shipped POSIX script, not a replacement vendor implementation.
func runFirewallPortRules(t *testing.T, body string, port int, code string) packScriptRun {
	t.Helper()
	bin := t.TempDir()
	stub := `#!/bin/sh
set -eu
[ "$#" = 6 ] && [ "$1" = -j ] && [ "$2" = -n ] && [ "$3" = -a ] && [ "$4" = -t ] && [ "$5" = list ] && [ "$6" = ruleset ] || exit 98
printf '%s\n' "$NFT_BODY"
if [ "$NFT_EXIT" != 0 ]; then
  printf '%s\n' 'packtest-netlink-refused' >&2
  exit "$NFT_EXIT"
fi
`
	if err := os.WriteFile(filepath.Join(bin, "nft"), []byte(stub), 0o700); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("/bin/sh", packagedScript(t, "firewall", "nft_port_rules.sh"), strconv.Itoa(port))
	cmd.Env = []string{"PATH=" + bin + string(os.PathListSeparator) + os.Getenv("PATH"), "NFT_BODY=" + body, "NFT_EXIT=" + code}
	var out, diagnostic bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &diagnostic
	run := packScriptRun{}
	err := cmd.Run()
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		run.exit = exit.ExitCode()
	} else if err != nil {
		t.Fatal(err)
	}
	run.stdout, run.stderr = out.String(), diagnostic.String()
	return run
}

func TestFirewallPortRulesConservativeMembership(t *testing.T) {
	rangePorts := map[string]any{"range": []any{9000, 9010}}
	set := func(members ...any) any { return map[string]any{"set": members} }
	for _, tt := range []struct {
		name    string
		op      any
		right   any
		port    int
		verdict string
	}{
		{"scalar_member", "==", set(80, 443), 443, "direct_match"},
		{"scalar_nonmember", "==", set(80, 443), 444, "no_match"},
		{"inverse_member", "!=", set(80, 443), 443, "no_match"},
		{"inverse_nonmember", "!=", set(80, 443), 444, "direct_match"},
		{"mixed_scalar", "==", set(8080, rangePorts), 8080, "direct_match"},
		{"range_lower", "==", set(8080, rangePorts), 9000, "direct_match"},
		{"range_upper", "==", set(8080, rangePorts), 9010, "direct_match"},
		{"range_outside", "==", set(8080, rangePorts), 9011, "no_match"},
		{"inverse_range_member", "!=", set(rangePorts), 9000, "no_match"},
		{"inverse_range_nonmember", "!=", set(rangePorts), 9011, "direct_match"},
		{"bare_array", "==", []any{80, 443}, 443, "direct_match"},
		{"bare_range", "!=", rangePorts, 9011, "direct_match"},
		{"numeric_string_alias", "eq", set("00443"), 443, "direct_match"},
		{"inverse_alias", "ne", set("443"), 80, "direct_match"},
		{"bitmask_not_membership", "in", set(443), 443, "unresolved"},
		{"unknown_after_match", "==", set(443, map[string]any{"map": "@ports"}), 443, "unresolved"},
		{"inverse_unknown", "!=", set(80, map[string]any{"map": "@ports"}), 443, "unresolved"},
		{"mapping_pair", "!=", set([]any{443, "accept"}), 80, "unresolved"},
		{"named_reference", "!=", "@ports", 443, "unresolved"},
		{"short_range", "==", set(map[string]any{"range": []any{9000}}), 9000, "unresolved"},
		{"reversed_range", "!=", set(map[string]any{"range": []any{9010, 9000}}), 443, "unresolved"},
		{"extra_range_field", "==", set(map[string]any{"range": []any{9000, 9010}, "unknown": 1}), 9000, "unresolved"},
		{"fractional_member", "!=", set(443.5), 80, "unresolved"},
		{"outside_port_domain", "!=", set(65536), 80, "unresolved"},
		{"numeric_string_newline", "!=", set("443\n"), 80, "unresolved"},
		{"empty_set", "==", map[string]any{"set": []any{}}, 443, "unresolved"},
		{"inverse_empty_set", "!=", map[string]any{"set": []any{}}, 443, "unresolved"},
		{"false_operator", false, set(443), 443, "unresolved"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			rule := map[string]any{
				"family": "inet", "table": "packtest", "chain": "input", "comment": tt.name,
				"expr": []any{map[string]any{"match": map[string]any{
					"op": tt.op, "left": map[string]any{"payload": map[string]any{"protocol": "tcp", "field": "dport"}}, "right": tt.right,
				}}},
			}
			body, err := json.Marshal(map[string]any{"nftables": []any{map[string]any{"rule": rule}}})
			if err != nil {
				t.Fatal(err)
			}
			run := runFirewallPortRules(t, string(body), tt.port, "0")
			if run.exit != 0 || run.stderr != "" {
				t.Fatalf("read failed: %#v", run)
			}
			var result struct {
				Port          int              `json:"port"`
				DirectMatches []map[string]any `json:"direct_matches"`
				Unresolved    []map[string]any `json:"unresolved"`
			}
			if err := json.Unmarshal([]byte(run.stdout), &result); err != nil {
				t.Fatalf("invalid JSON: %v: %s", err, run.stdout)
			}
			if result.Port != tt.port {
				t.Fatalf("wrong port: %#v", result)
			}
			var selected []map[string]any
			switch tt.verdict {
			case "direct_match":
				selected = result.DirectMatches
				if len(result.Unresolved) != 0 {
					t.Fatalf("known match also unresolved: %#v", result)
				}
			case "unresolved":
				selected = result.Unresolved
				if len(result.DirectMatches) != 0 {
					t.Fatalf("unknown falsely matched: %#v", result)
				}
			case "no_match":
				if len(result.DirectMatches)+len(result.Unresolved) != 0 {
					t.Fatalf("nonmember selected: %#v", result)
				}
				return
			}
			if len(selected) != 1 || selected[0]["comment"] != tt.name || selected[0]["port_evaluation"] != tt.verdict {
				t.Fatalf("wrong membership classification: %#v", result)
			}
		})
	}
}

func TestFirewallPortRulesSourceFailures(t *testing.T) {
	// Even valid partial JSON from a failed read is not a successful ruleset.
	run := runFirewallPortRules(t, `{"nftables":[]}`, 443, "23")
	if run.exit != 23 || run.stdout != "" || !strings.Contains(run.stderr, "packtest-netlink-refused") {
		t.Fatalf("source error obscured: %#v", run)
	}
	for _, body := range []string{"", "not-json", `{}`, `[]`, `null`, `{"nftables":null}`, `{"nftables":{}}`} {
		run := runFirewallPortRules(t, body, 443, "0")
		if run.exit == 0 {
			t.Fatalf("invalid source accepted: %#v", run)
		}
	}
}

func TestFirewallPortRulesRequiresExplicitOperator(t *testing.T) {
	for _, operator := range []string{"missing", "null"} {
		for _, right := range []struct {
			name  string
			value any
		}{
			{"scalar", 443},
			{"set", map[string]any{"set": []any{443}}},
		} {
			for _, port := range []int{443, 444} {
				t.Run(operator+"_"+right.name+"_"+strconv.Itoa(port), func(t *testing.T) {
					match := map[string]any{
						"left":  map[string]any{"payload": map[string]any{"protocol": "tcp", "field": "dport"}},
						"right": right.value,
					}
					if operator == "null" {
						match["op"] = nil
					}
					body, err := json.Marshal(map[string]any{"nftables": []any{map[string]any{
						"rule": map[string]any{"expr": []any{map[string]any{"match": match}}},
					}}})
					if err != nil {
						t.Fatal(err)
					}
					run := runFirewallPortRules(t, string(body), port, "0")
					var result struct {
						DirectMatches []any `json:"direct_matches"`
						Unresolved    []any `json:"unresolved"`
					}
					if err := json.Unmarshal([]byte(run.stdout), &result); err != nil {
						t.Fatalf("invalid JSON: %v: %#v", err, run)
					}
					if run.exit != 0 || run.stderr != "" || len(result.DirectMatches) != 0 || len(result.Unresolved) != 1 {
						t.Fatalf("operator inferred from malformed match: %#v, %#v", result, run)
					}
				})
			}
		}
	}
}
