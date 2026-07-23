package infraops

import (
	"context"
	"encoding/json"
	"fmt"
)

func (a *App) verifyPackEnvironment(ctx context.Context, repo, environment string) error {
	data, err := a.output(ctx, a.Root, nil, "gh", "api",
		"repos/"+repo+"/environments/"+environment)
	if err != nil {
		return err
	}
	var payload struct {
		CanAdminsBypass        bool `json:"can_admins_bypass"`
		DeploymentBranchPolicy struct {
			ProtectedBranches    bool `json:"protected_branches"`
			CustomBranchPolicies bool `json:"custom_branch_policies"`
		} `json:"deployment_branch_policy"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return fmt.Errorf("decoding GitHub environment: %w", err)
	}
	if payload.CanAdminsBypass ||
		!payload.DeploymentBranchPolicy.ProtectedBranches ||
		payload.DeploymentBranchPolicy.CustomBranchPolicies {
		return fmt.Errorf("%s must disable admin bypass and allow only protected branches", environment)
	}
	fmt.Fprintf(a.Out, "verified: %s/%s binds WIF credentials to protected main\n", repo, environment)
	return nil
}
