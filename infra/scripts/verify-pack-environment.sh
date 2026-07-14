#!/usr/bin/env bash
set -euo pipefail

repo=${1:-AndrewDryga/emisar}
environment=${2:-pack-registry-production}

payload=$(gh api "repos/${repo}/environments/${environment}")

jq -e '
  .can_admins_bypass == false and
  any(.protection_rules[]?; .type == "required_reviewers" and .prevent_self_review == true and (.reviewers | length > 0)) and
  .deployment_branch_policy.protected_branches == true and
  .deployment_branch_policy.custom_branch_policies == false
' <<<"$payload" >/dev/null || {
  echo "${environment} must require a reviewer, prevent self-review, disable admin bypass, and allow only protected branches" >&2
  exit 1
}

echo "verified: ${repo}/${environment} protects the identity-bearing pack publisher"
