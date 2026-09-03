package infraops

import (
	"bytes"
	"strings"
	"testing"
)

const (
	packApprovalEnvironment = `{
  "can_admins_bypass": true,
  "protection_rules": [
    {"type":"required_reviewers","prevent_self_review":false,"reviewers":[{"type":"User","reviewer":{"login":"release-reviewer"}}]},
    {"type":"branch_policy"}
  ],
  "deployment_branch_policy": {"protected_branches":true,"custom_branch_policies":false}
}`
	packProductionEnvironment = `{
  "can_admins_bypass": false,
  "protection_rules": [{"type":"branch_policy"}],
  "deployment_branch_policy": {"protected_branches":true,"custom_branch_policies":false}
}`
	publicReleasesEnvironment = `{
  "can_admins_bypass": false,
  "protection_rules": [
    {"type":"branch_policy"},
    {"type":"required_reviewers","prevent_self_review":true,"reviewers":[{"type":"User","reviewer":{"login":"release-reviewer"}}]}
  ],
  "deployment_branch_policy": {"protected_branches":false,"custom_branch_policies":true}
}`
	mcpRegistryEnvironment = `{
  "can_admins_bypass": false,
  "protection_rules": [{"type":"branch_policy"}],
  "deployment_branch_policy": {"protected_branches":false,"custom_branch_policies":true}
}`
	publicReleasePolicies = `{
  "total_count": 2,
  "branch_policies": [
    {"name":"runner-v*","type":"tag"},
    {"name":"mcp-v*","type":"tag"}
  ]
}`
	mcpRegistryPolicies = `{
  "total_count": 1,
  "branch_policies": [{"name":"main","type":"branch"}]
}`
)

func TestReleaseEnvironmentProfiles(t *testing.T) {
	tests := []struct {
		name            string
		environment     string
		environmentJSON string
		policiesJSON    string
	}{
		{name: "pack approval", environment: "pack-registry-approval", environmentJSON: packApprovalEnvironment},
		{name: "pack production", environment: "pack-registry-production", environmentJSON: packProductionEnvironment},
		{name: "public releases", environment: "public-releases", environmentJSON: publicReleasesEnvironment, policiesJSON: publicReleasePolicies},
		{name: "MCP registry", environment: "mcp-registry-publication", environmentJSON: mcpRegistryEnvironment, policiesJSON: mcpRegistryPolicies},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			profile := releaseEnvironmentProfiles[test.environment]
			if err := validateReleaseEnvironment(profile, []byte(test.environmentJSON)); err != nil {
				t.Fatal(err)
			}
			if len(profile.customPolicies) != 0 {
				if err := validateDeploymentBranchPolicies(profile.customPolicies, []byte(test.policiesJSON)); err != nil {
					t.Fatal(err)
				}
			}
		})
	}
}

func TestReleaseEnvironmentRejectsWeakenedOrMalformedProtection(t *testing.T) {
	tests := []struct {
		name        string
		environment string
		payload     string
		want        string
	}{
		{name: "malformed JSON", environment: "pack-registry-production", payload: `{`, want: "decoding GitHub environment"},
		{name: "missing deployment policy", environment: "pack-registry-production", payload: `{"can_admins_bypass":false,"protection_rules":[]}`, want: "deployment branch policy is missing"},
		{name: "missing deployment mode field", environment: "pack-registry-production", payload: `{"can_admins_bypass":false,"protection_rules":[],"deployment_branch_policy":{"protected_branches":true}}`, want: "deployment branch policy is missing"},
		{name: "wrong deployment mode", environment: "pack-registry-production", payload: mcpRegistryEnvironment, want: "policy mode does not match"},
		{name: "missing admin bypass", environment: "pack-registry-production", payload: `{"protection_rules":[],"deployment_branch_policy":{"protected_branches":true,"custom_branch_policies":false}}`, want: "admin bypass setting is missing"},
		{name: "admin bypass", environment: "pack-registry-production", payload: strings.Replace(packProductionEnvironment, `"can_admins_bypass": false`, `"can_admins_bypass": true`, 1), want: "admin bypass must be disabled"},
		{name: "missing protection rules", environment: "pack-registry-production", payload: `{"can_admins_bypass":false,"deployment_branch_policy":{"protected_branches":true,"custom_branch_policies":false}}`, want: "protection rules are missing"},
		{name: "missing rule type", environment: "pack-registry-production", payload: `{"can_admins_bypass":false,"protection_rules":[{}],"deployment_branch_policy":{"protected_branches":true,"custom_branch_policies":false}}`, want: "protection rule type is missing"},
		{name: "reviewer on no-reviewer profile", environment: "pack-registry-production", payload: strings.Replace(packApprovalEnvironment, `"can_admins_bypass": true`, `"can_admins_bypass": false`, 1), want: "reviewers must not be configured"},
		{name: "missing reviewer rule", environment: "pack-registry-approval", payload: packProductionEnvironment, want: "exactly one required-reviewers rule"},
		{name: "duplicate reviewer rule", environment: "pack-registry-approval", payload: strings.Replace(packApprovalEnvironment, `{"type":"branch_policy"}`, `{"type":"required_reviewers","reviewers":[{}]}`, 1), want: "exactly one required-reviewers rule"},
		{name: "zero reviewers", environment: "pack-registry-approval", payload: strings.Replace(packApprovalEnvironment, `"reviewers":[{"type":"User","reviewer":{"login":"release-reviewer"}}]`, `"reviewers":[]`, 1), want: "exactly 1 reviewer entry"},
		{name: "multiple reviewers", environment: "pack-registry-approval", payload: strings.Replace(packApprovalEnvironment, `"reviewers":[{"type":"User","reviewer":{"login":"release-reviewer"}}]`, `"reviewers":[{},{}]`, 1), want: "exactly 1 reviewer entry"},
		{name: "null reviewer", environment: "pack-registry-approval", payload: strings.Replace(packApprovalEnvironment, `{"type":"User","reviewer":{"login":"release-reviewer"}}`, `null`, 1), want: "reviewer entries must be objects"},
		{name: "missing self-review setting", environment: "public-releases", payload: strings.Replace(publicReleasesEnvironment, `"prevent_self_review":true,`, ``, 1), want: "prevent-self-review setting is missing"},
		{name: "self review allowed", environment: "public-releases", payload: strings.Replace(publicReleasesEnvironment, `"prevent_self_review":true`, `"prevent_self_review":false`, 1), want: "prevent self-review must be enabled"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			profile := releaseEnvironmentProfiles[test.environment]
			err := validateReleaseEnvironment(profile, []byte(test.payload))
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want it to contain %q", err, test.want)
			}
		})
	}
}

func TestDeploymentBranchPoliciesMustMatchExactly(t *testing.T) {
	want := releaseEnvironmentProfiles["public-releases"].customPolicies
	tests := []struct {
		name    string
		payload string
		want    string
	}{
		{name: "malformed JSON", payload: `{`, want: "decoding deployment branch policies"},
		{name: "missing total", payload: `{"branch_policies":[]}`, want: "missing required fields"},
		{name: "missing policies", payload: `{"total_count":0}`, want: "missing required fields"},
		{name: "truncated", payload: `{"total_count":3,"branch_policies":[{"name":"runner-v*","type":"tag"},{"name":"mcp-v*","type":"tag"}]}`, want: "truncated"},
		{name: "missing policy name", payload: `{"total_count":2,"branch_policies":[{"type":"tag"},{"name":"mcp-v*","type":"tag"}]}`, want: "missing its name or type"},
		{name: "missing policy type", payload: `{"total_count":2,"branch_policies":[{"name":"runner-v*"},{"name":"mcp-v*","type":"tag"}]}`, want: "missing its name or type"},
		{name: "duplicate", payload: `{"total_count":2,"branch_policies":[{"name":"runner-v*","type":"tag"},{"name":"runner-v*","type":"tag"}]}`, want: "duplicated"},
		{name: "missing", payload: `{"total_count":1,"branch_policies":[{"name":"runner-v*","type":"tag"}]}`, want: "do not match"},
		{name: "extra", payload: `{"total_count":3,"branch_policies":[{"name":"runner-v*","type":"tag"},{"name":"mcp-v*","type":"tag"},{"name":"v*","type":"tag"}]}`, want: "do not match"},
		{name: "wrong type", payload: `{"total_count":2,"branch_policies":[{"name":"runner-v*","type":"branch"},{"name":"mcp-v*","type":"tag"}]}`, want: "do not match"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			err := validateDeploymentBranchPolicies(want, []byte(test.payload))
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want it to contain %q", err, test.want)
			}
		})
	}
}

func TestVerifyReleaseEnvironmentRequiresKnownExplicitScope(t *testing.T) {
	var output bytes.Buffer
	app := New(t.TempDir(), strings.NewReader(""), &output, &output)
	for _, args := range [][]string{
		{"verify-release-environment"},
		{"verify-release-environment", "AndrewDryga/emisar"},
		{"verify-release-environment", "AndrewDryga/emisar", "pack-registry-production", "extra"},
	} {
		if err := app.Run(t.Context(), args); err == nil || !IsUsage(err) {
			t.Fatalf("Run(%v) error = %v, want usage error", args, err)
		}
	}
	if err := app.Run(t.Context(), []string{
		"verify-release-environment", "AndrewDryga/emisar", "not-a-release-environment",
	}); err == nil || !strings.Contains(err.Error(), "unknown release environment") {
		t.Fatalf("unknown environment error = %v", err)
	}
}

func TestGitHubRepositoryPath(t *testing.T) {
	got, err := githubRepositoryPath("Andrew Dryga/emisar repo")
	if err != nil {
		t.Fatal(err)
	}
	if got != "Andrew%20Dryga/emisar%20repo" {
		t.Fatalf("path = %q", got)
	}
	for _, invalid := range []string{"", "owner", "/repo", "owner/", "owner/repo/extra"} {
		if _, err := githubRepositoryPath(invalid); err == nil {
			t.Fatalf("githubRepositoryPath(%q) unexpectedly passed", invalid)
		}
	}
}
