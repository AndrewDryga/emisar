package infraops

import (
	"bytes"
	"os"
	"strings"
	"testing"
)

func TestBackupWorkflowSafetyContracts(t *testing.T) {
	template, err := os.ReadFile("../../../infra/runtime/backup-check/workflow.yaml")
	if err != nil {
		t.Fatal(err)
	}
	// Unit tests substitute the three fixture scalars without requiring Terraform
	// in the tooling job. The infra gate passes actual templatefile output to the
	// same validator, covering interpolation and escaping in the deployed shape.
	data := []byte(strings.NewReplacer(
		"${jsonencode(project_id)}", `"test-project"`,
		"${jsonencode(instance_id)}", `"emisar"`,
		"${jsonencode(metric_type)}", `"custom.googleapis.com/emisar/cloudsql/last_automated_backup_timestamp"`,
		"$${", "${",
	).Replace(string(template)))
	if err := validateBackupWorkflow(data); err != nil {
		t.Fatal(err)
	}

	for _, tc := range []struct{ name, from, to string }{
		{"different project", `project_id: "test-project"`, `project_id: "other-project"`},
		{"all instances", "instance: ${instance_id}", `instance: "-"`},
		{"missing pagination", "next: list_backups", "next: publish"},
		{"manual backups accepted", `backup.type != "AUTOMATED" or backup.status != "SUCCESSFUL"`, `backup.status != "SUCCESSFUL"`},
		{"failed backups accepted", `backup.type != "AUTOMATED" or backup.status != "SUCCESSFUL"`, `backup.type != "AUTOMATED"`},
		{"wrong instance accepted", "backup.instance != instance_id", "false"},
		{"start time used", "time.parse(backup.endTime)", "time.parse(backup.startTime)"},
		{"future timestamp accepted", "completed_at <= 0 or completed_at > sys.now()", "completed_at <= 0"},
		{"oldest completion used", "math.max(latest_success, completed_at)", "math.min(latest_success, completed_at)"},
		{"truncated inventory published", "raise: \"Cloud SQL backup inventory pagination did not complete\"", "next: publish"},
		{"historical metric point", "endTime: ${time.format(sys.now())}", "endTime: ${time.format(latest_success)}"},
		{"false healthy value", "doubleValue: ${latest_success}", "doubleValue: ${sys.now()}"},
		{"wrong auth type", "type: OAuth2", "type: OIDC"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if !bytes.Contains(data, []byte(tc.from)) {
				t.Fatalf("mutation source missing: %s", tc.from)
			}
			changed := strings.Replace(string(data), tc.from, tc.to, 1)
			if err := validateBackupWorkflow([]byte(changed)); err == nil {
				t.Fatal("unsafe workflow accepted")
			}
		})
	}
}

func TestBackupAlertUsesFreshObservationForFullThirtyHours(t *testing.T) {
	data, err := os.ReadFile("../../../infra/monitoring_backup.tf")
	if err != nil {
		t.Fatal(err)
	}
	if err := requireText("backup alerts", string(data),
		`time() - last_over_time(${local.backup_timestamp_series}[30m]) >= 108000`,
		`absent_over_time(${local.backup_timestamp_series}[30m])`,
		`resource "google_monitoring_alert_policy" "db_backup_checker_stale"`,
	); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "[30h]") || strings.Contains(string(data), "[25h]") {
		t.Fatal("backup alert uses an unsupported long metric lookback")
	}
}
