package infraops

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"strings"
)

type releaseEnvironmentProfile struct {
	blockAdminBypass  bool
	reviewerCount     int
	preventSelfReview *bool
	protectedBranches bool
	customPolicies    []deploymentBranchPolicy
}

type githubEnvironment struct {
	CanAdminsBypass        *bool                       `json:"can_admins_bypass"`
	ProtectionRules        *[]environmentRule          `json:"protection_rules"`
	DeploymentBranchPolicy *deploymentBranchPolicyMode `json:"deployment_branch_policy"`
}

type environmentRule struct {
	Type              string                 `json:"type"`
	PreventSelfReview *bool                  `json:"prevent_self_review"`
	Reviewers         *[]environmentReviewer `json:"reviewers"`
}

type environmentReviewer struct {
	Type     string          `json:"type"`
	Reviewer json.RawMessage `json:"reviewer"`
}

type deploymentBranchPolicyMode struct {
	ProtectedBranches    *bool `json:"protected_branches"`
	CustomBranchPolicies *bool `json:"custom_branch_policies"`
}

type deploymentBranchPolicies struct {
	TotalCount     *int                      `json:"total_count"`
	BranchPolicies *[]deploymentBranchPolicy `json:"branch_policies"`
}

type deploymentBranchPolicy struct {
	Name string `json:"name"`
	Type string `json:"type"`
}

func boolPointer(value bool) *bool { return &value }

var releaseEnvironmentProfiles = map[string]releaseEnvironmentProfile{
	"pack-registry-approval": {
		reviewerCount:     1,
		protectedBranches: true,
	},
	"pack-registry-production": {
		blockAdminBypass:  true,
		protectedBranches: true,
	},
	"public-releases": {
		blockAdminBypass:  true,
		reviewerCount:     1,
		preventSelfReview: boolPointer(true),
		customPolicies: []deploymentBranchPolicy{
			{Name: "mcp-v*", Type: "tag"},
			{Name: "runner-v*", Type: "tag"},
		},
	},
	"mcp-registry-publication": {
		blockAdminBypass: true,
		customPolicies: []deploymentBranchPolicy{
			{Name: "main", Type: "branch"},
		},
	},
}

func (a *App) verifyReleaseEnvironment(ctx context.Context, repo, environment string) error {
	profile, ok := releaseEnvironmentProfiles[environment]
	if !ok {
		return fmt.Errorf("unknown release environment %q", environment)
	}
	repoPath, err := githubRepositoryPath(repo)
	if err != nil {
		return err
	}

	data, err := a.output(ctx, a.Root, nil, "gh", "api",
		"-H", "Accept: application/vnd.github+json",
		"-H", "X-GitHub-Api-Version: 2022-11-28",
		"repos/"+repoPath+"/environments/"+url.PathEscape(environment))
	if err != nil {
		return err
	}
	if err := validateReleaseEnvironment(profile, data); err != nil {
		return fmt.Errorf("%s: %w", environment, err)
	}

	if len(profile.customPolicies) != 0 {
		data, err = a.output(ctx, a.Root, nil, "gh", "api",
			"-H", "Accept: application/vnd.github+json",
			"-H", "X-GitHub-Api-Version: 2022-11-28",
			"repos/"+repoPath+"/environments/"+url.PathEscape(environment)+
				"/deployment-branch-policies?per_page=100")
		if err != nil {
			return err
		}
		if err := validateDeploymentBranchPolicies(profile.customPolicies, data); err != nil {
			return fmt.Errorf("%s: %w", environment, err)
		}
	}

	fmt.Fprintf(a.Out, "verified: %s/%s matches its release policy\n", repo, environment)
	return nil
}

func githubRepositoryPath(repo string) (string, error) {
	owner, name, ok := strings.Cut(repo, "/")
	if !ok || owner == "" || name == "" || strings.Contains(name, "/") {
		return "", fmt.Errorf("GitHub repository must be owner/name, got %q", repo)
	}
	return url.PathEscape(owner) + "/" + url.PathEscape(name), nil
}

func validateReleaseEnvironment(profile releaseEnvironmentProfile, data []byte) error {
	var environment githubEnvironment
	if err := decodeJSONObject(data, &environment); err != nil {
		return fmt.Errorf("decoding GitHub environment: %w", err)
	}
	if environment.DeploymentBranchPolicy == nil ||
		environment.DeploymentBranchPolicy.ProtectedBranches == nil ||
		environment.DeploymentBranchPolicy.CustomBranchPolicies == nil {
		return fmt.Errorf("deployment branch policy is missing required fields")
	}
	wantCustom := len(profile.customPolicies) != 0
	if *environment.DeploymentBranchPolicy.ProtectedBranches != profile.protectedBranches ||
		*environment.DeploymentBranchPolicy.CustomBranchPolicies != wantCustom {
		return fmt.Errorf("deployment branch policy mode does not match the required profile")
	}
	if profile.blockAdminBypass {
		if environment.CanAdminsBypass == nil {
			return fmt.Errorf("admin bypass setting is missing")
		}
		if *environment.CanAdminsBypass {
			return fmt.Errorf("admin bypass must be disabled")
		}
	}
	if environment.ProtectionRules == nil {
		return fmt.Errorf("protection rules are missing")
	}

	var reviewerRules []environmentRule
	for _, rule := range *environment.ProtectionRules {
		if rule.Type == "" {
			return fmt.Errorf("protection rule type is missing")
		}
		if rule.Type == "required_reviewers" {
			reviewerRules = append(reviewerRules, rule)
		}
	}
	if profile.reviewerCount == 0 {
		if len(reviewerRules) != 0 {
			return fmt.Errorf("reviewers must not be configured")
		}
		return nil
	}
	if len(reviewerRules) != 1 {
		return fmt.Errorf("exactly one required-reviewers rule must be configured")
	}
	rule := reviewerRules[0]
	if rule.Reviewers == nil || len(*rule.Reviewers) != profile.reviewerCount {
		return fmt.Errorf("exactly %d reviewer entry must be configured", profile.reviewerCount)
	}
	for _, reviewer := range *rule.Reviewers {
		trimmed := bytes.TrimSpace(reviewer.Reviewer)
		if (reviewer.Type != "User" && reviewer.Type != "Team") ||
			len(trimmed) == 0 || trimmed[0] != '{' {
			return fmt.Errorf("reviewer entries must be objects")
		}
	}
	if profile.preventSelfReview != nil {
		if rule.PreventSelfReview == nil {
			return fmt.Errorf("prevent-self-review setting is missing")
		}
		if *rule.PreventSelfReview != *profile.preventSelfReview {
			return fmt.Errorf("prevent self-review must be enabled")
		}
	}
	return nil
}

func validateDeploymentBranchPolicies(want []deploymentBranchPolicy, data []byte) error {
	var payload deploymentBranchPolicies
	if err := decodeJSONObject(data, &payload); err != nil {
		return fmt.Errorf("decoding deployment branch policies: %w", err)
	}
	if payload.TotalCount == nil || payload.BranchPolicies == nil {
		return fmt.Errorf("deployment branch-policy response is missing required fields")
	}
	if *payload.TotalCount != len(*payload.BranchPolicies) {
		return fmt.Errorf("deployment branch-policy response is truncated")
	}

	actual := make(map[deploymentBranchPolicy]struct{}, len(*payload.BranchPolicies))
	for _, policy := range *payload.BranchPolicies {
		if policy.Name == "" || policy.Type == "" {
			return fmt.Errorf("deployment branch policy is missing its name or type")
		}
		if _, duplicate := actual[policy]; duplicate {
			return fmt.Errorf("deployment branch policy %s:%s is duplicated", policy.Type, policy.Name)
		}
		actual[policy] = struct{}{}
	}
	if len(actual) != len(want) {
		return fmt.Errorf("deployment branch policies do not match the required profile")
	}
	for _, policy := range want {
		if _, ok := actual[policy]; !ok {
			return fmt.Errorf("deployment branch policies do not match the required profile")
		}
	}
	return nil
}

func decodeJSONObject(data []byte, destination any) error {
	return json.Unmarshal(data, destination)
}
