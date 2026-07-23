package infraops

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

var drillIDPattern = regexp.MustCompile(`^edrill-([0-9]{10})-([0-9a-f]{6})$`)

type sqlInstance struct {
	Name     string `json:"name"`
	Settings struct {
		UserLabels map[string]string `json:"userLabels"`
	} `json:"settings"`
}

type computeInstance struct {
	Name   string            `json:"name"`
	Zone   string            `json:"zone"`
	Labels map[string]string `json:"labels"`
}

type serviceAccount struct {
	Email       string `json:"email"`
	DisplayName string `json:"displayName"`
}

type iamPolicy struct {
	Bindings []struct {
		Role    string   `json:"role"`
		Members []string `json:"members"`
	} `json:"bindings"`
}

type drillInventory struct {
	sql      []sqlInstance
	vms      []computeInstance
	accounts []serviceAccount
}

func decodeJSON[T any](data []byte) (T, error) {
	var value T
	if err := json.Unmarshal(data, &value); err != nil {
		return value, err
	}
	return value, nil
}

func (a *App) drillInventory(ctx context.Context, project string) (drillInventory, error) {
	var inventory drillInventory
	sqlData, err := a.output(ctx, a.Root, nil, "gcloud", "sql", "instances", "list",
		"--project="+project, "--format=json")
	if err != nil {
		return inventory, err
	}
	inventory.sql, err = decodeJSON[[]sqlInstance](sqlData)
	if err != nil {
		return inventory, fmt.Errorf("decoding SQL inventory: %w", err)
	}
	vmData, err := a.output(ctx, a.Root, nil, "gcloud", "compute", "instances", "list",
		"--project="+project, "--format=json")
	if err != nil {
		return inventory, err
	}
	inventory.vms, err = decodeJSON[[]computeInstance](vmData)
	if err != nil {
		return inventory, fmt.Errorf("decoding VM inventory: %w", err)
	}
	accountData, err := a.output(ctx, a.Root, nil, "gcloud", "iam", "service-accounts", "list",
		"--project="+project, "--format=json")
	if err != nil {
		return inventory, err
	}
	inventory.accounts, err = decodeJSON[[]serviceAccount](accountData)
	if err != nil {
		return inventory, fmt.Errorf("decoding service-account inventory: %w", err)
	}
	return inventory, nil
}

func discoverDrillIDs(inventory drillInventory) []string {
	ids := make(map[string]struct{})
	add := func(candidate string) {
		if drillIDPattern.MatchString(candidate) {
			ids[candidate] = struct{}{}
		}
	}
	for _, instance := range inventory.sql {
		add(instance.Settings.UserLabels["drill_id"])
		add(strings.TrimSuffix(instance.Name, "-db"))
	}
	for _, vm := range inventory.vms {
		add(vm.Labels["drill_id"])
		add(strings.TrimSuffix(vm.Name, "-probe"))
	}
	for _, account := range inventory.accounts {
		add(strings.SplitN(account.Email, "@", 2)[0])
	}
	result := make([]string, 0, len(ids))
	for id := range ids {
		result = append(result, id)
	}
	sort.Strings(result)
	return result
}

func drillCreatedAt(id string) (time.Time, error) {
	match := drillIDPattern.FindStringSubmatch(id)
	if match == nil {
		return time.Time{}, fmt.Errorf("refusing unexpected drill id: %s", id)
	}
	created, err := time.ParseInLocation("0601021504", match[1], time.UTC)
	if err != nil {
		return time.Time{}, fmt.Errorf("parsing drill id %s: %w", id, err)
	}
	return created, nil
}

func zoneName(zone string) string {
	parts := strings.Split(zone, "/")
	return parts[len(parts)-1]
}

func hasBinding(policy iamPolicy, role, member string) bool {
	for _, binding := range policy.Bindings {
		if binding.Role != role {
			continue
		}
		for _, candidate := range binding.Members {
			if candidate == member {
				return true
			}
		}
	}
	return false
}

func anyBinding(policy iamPolicy, member string) bool {
	for _, binding := range policy.Bindings {
		for _, candidate := range binding.Members {
			if candidate == member {
				return true
			}
		}
	}
	return false
}

func (a *App) projectPolicy(ctx context.Context, project string) (iamPolicy, error) {
	data, err := a.output(ctx, a.Root, nil, "gcloud", "projects", "get-iam-policy",
		project, "--format=json")
	if err != nil {
		return iamPolicy{}, err
	}
	policy, err := decodeJSON[iamPolicy](data)
	if err != nil {
		return iamPolicy{}, fmt.Errorf("decoding project IAM policy: %w", err)
	}
	return policy, nil
}

func (a *App) cleanupDrills(ctx context.Context, args []string) error {
	apply := false
	requested := ""
	switch {
	case len(args) == 0:
	case len(args) == 1 && args[0] == "--apply":
		apply = true
	case len(args) == 2 && args[0] == "--apply":
		apply, requested = true, args[1]
	default:
		return usage("usage: ./run ops drill cleanup [--apply [DRILL_ID]]")
	}
	project := os.Getenv("PROJECT_ID")
	if project == "" {
		project = "emisar"
	}
	if err := a.require("gcloud"); err != nil {
		return err
	}

	var ids []string
	if requested != "" {
		if _, err := drillCreatedAt(requested); err != nil {
			return err
		}
		ids = []string{requested}
	} else {
		inventory, err := a.drillInventory(ctx, project)
		if err != nil {
			return err
		}
		ids = discoverDrillIDs(inventory)
	}

	failures := 0
	now := time.Now().UTC()
	for _, id := range ids {
		created, err := drillCreatedAt(id)
		if err != nil {
			fmt.Fprintln(a.Err, err)
			failures++
			continue
		}
		age := now.Sub(created)
		if requested == "" && age < 12*time.Hour {
			fmt.Fprintf(a.Out, "keeping active drill %s (age %s; janitor threshold 12h)\n",
				id, age.Truncate(time.Second))
			continue
		}
		fmt.Fprintf(a.Out, "cleanup candidate: %s\n", id)
		if !apply {
			continue
		}
		if err := a.cleanupDrill(ctx, project, id); err != nil {
			fmt.Fprintln(a.Err, err)
			failures++
		}
	}
	if failures != 0 {
		return fmt.Errorf("%d recovery drill cleanup(s) failed", failures)
	}
	return nil
}

func (a *App) cleanupDrill(ctx context.Context, project, id string) error {
	clone := id + "-db"
	vmName := id + "-probe"
	accountEmail := id + "@" + project + ".iam.gserviceaccount.com"
	member := "serviceAccount:" + accountEmail

	inventory, err := a.drillInventory(ctx, project)
	if err != nil {
		return fmt.Errorf("inventory failed for %s; refusing to infer absence: %w", id, err)
	}
	policy, err := a.projectPolicy(ctx, project)
	if err != nil {
		return fmt.Errorf("IAM inventory failed for %s; refusing to infer absence: %w", id, err)
	}

	var accounts []serviceAccount
	for _, account := range inventory.accounts {
		if account.Email == accountEmail {
			accounts = append(accounts, account)
		}
	}
	if len(accounts) > 1 {
		return fmt.Errorf("refusing ambiguous service-account inventory: %s", accountEmail)
	}
	accountOwned := len(accounts) == 1
	if accountOwned && accounts[0].DisplayName != "Temporary recovery drill "+id {
		return fmt.Errorf("refusing service account with unexpected display name: %s", accountEmail)
	}

	var failures []error
	for _, vm := range inventory.vms {
		if vm.Name != vmName {
			continue
		}
		if vm.Labels["purpose"] != "recovery-drill" || vm.Labels["drill_id"] != id {
			failures = append(failures, fmt.Errorf("refusing VM with mismatched ownership labels: %s", vmName))
			continue
		}
		if err := a.run(ctx, a.Root, nil, "gcloud", "compute", "instances", "delete",
			vmName, "--project="+project, "--zone="+zoneName(vm.Zone), "--quiet"); err != nil {
			failures = append(failures, err)
		}
	}

	temp, err := os.MkdirTemp("", "emisar-drill-cleanup-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(temp)
	conditionPath := filepath.Join(temp, id+"-condition.json")
	condition := map[string]string{
		"title": id + "-only", "description": "Temporary non-production recovery drill",
		"expression": fmt.Sprintf(
			"resource.name == 'projects/%s/instances/%s' && resource.type == 'sqladmin.googleapis.com/Instance'",
			project, clone),
	}
	conditionData, _ := json.Marshal(condition)
	if err := os.WriteFile(conditionPath, append(conditionData, '\n'), 0o600); err != nil {
		return err
	}
	for _, role := range []string{"roles/cloudsql.client", "roles/cloudsql.instanceUser"} {
		if hasBinding(policy, role, member) {
			if err := a.run(ctx, a.Root, nil, "gcloud", "projects", "remove-iam-policy-binding",
				project, "--member="+member, "--role="+role,
				"--condition-from-file="+conditionPath, "--quiet"); err != nil {
				failures = append(failures, err)
			}
		}
	}

	var clones []sqlInstance
	for _, instance := range inventory.sql {
		if instance.Name == clone {
			clones = append(clones, instance)
		}
	}
	if len(clones) > 1 {
		return fmt.Errorf("refusing ambiguous SQL inventory: %s", clone)
	}
	if len(clones) == 1 {
		labels := clones[0].Settings.UserLabels
		exactOwnership := labels["purpose"] == "recovery-drill" && labels["drill_id"] == id
		preLabelOwnership := labels["purpose"] == "" && labels["drill_id"] == "" && accountOwned
		if !exactOwnership && !preLabelOwnership {
			return fmt.Errorf("refusing SQL instance without exact ownership proof: %s", clone)
		}
		if preLabelOwnership {
			fmt.Fprintf(a.Out, "recovering pre-label clone whose matching service account proves drill ownership: %s\n", clone)
		}
		if err := a.run(ctx, a.Root, nil, "gcloud", "sql", "instances", "patch",
			clone, "--project="+project, "--no-deletion-protection", "--quiet"); err != nil {
			failures = append(failures, err)
		} else if err := a.run(ctx, a.Root, nil, "gcloud", "sql", "instances", "delete",
			clone, "--project="+project, "--quiet"); err != nil {
			failures = append(failures, err)
		}
	}
	if accountOwned {
		if err := a.run(ctx, a.Root, nil, "gcloud", "iam", "service-accounts", "delete",
			accountEmail, "--project="+project, "--quiet"); err != nil {
			failures = append(failures, err)
		}
	}

	finalInventory, err := a.drillInventory(ctx, project)
	if err != nil {
		return fmt.Errorf("final inventory failed for %s; cleanup is unverified: %w", id, err)
	}
	finalPolicy, err := a.projectPolicy(ctx, project)
	if err != nil {
		return fmt.Errorf("final IAM inventory failed for %s; cleanup is unverified: %w", id, err)
	}
	for _, vm := range finalInventory.vms {
		if vm.Name == vmName {
			return fmt.Errorf("cleanup verification found VM %s", vmName)
		}
	}
	for _, instance := range finalInventory.sql {
		if instance.Name == clone {
			return fmt.Errorf("cleanup verification found SQL instance %s", clone)
		}
	}
	for _, account := range finalInventory.accounts {
		if account.Email == accountEmail {
			return fmt.Errorf("cleanup verification found service account %s", accountEmail)
		}
	}
	if anyBinding(finalPolicy, member) {
		return fmt.Errorf("cleanup verification found IAM binding for %s", accountEmail)
	}
	if err := errors.Join(failures...); err != nil {
		return fmt.Errorf("cleanup commands failed for %s: %w", id, err)
	}
	fmt.Fprintf(a.Out, "cleanup verified: %s has no VM, SQL instance, service account, or IAM binding\n", id)
	return nil
}
