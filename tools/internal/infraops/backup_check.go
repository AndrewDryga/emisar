package infraops

import (
	"fmt"
	"reflect"
	"strconv"
	"strings"

	"go.yaml.in/yaml/v3"
)

// Check the rendered, deployed document, not a second implementation of backup
// selection. These are the safety-critical branches and their order; Google
// still owns expression compilation and actual connector execution.
func validateBackupWorkflow(data []byte) error {
	var document map[string]any
	if err := yaml.Unmarshal(data, &document); err != nil {
		return fmt.Errorf("backup workflow YAML: %w", err)
	}
	main, ok := document["main"].(map[string]any)
	if !ok || len(document) != 1 || len(main) != 1 {
		return fmt.Errorf("backup workflow must have one no-input main workflow")
	}
	steps, ok := main["steps"].([]any)
	if !ok {
		return fmt.Errorf("backup workflow main steps missing")
	}
	wantNames := []string{"initialize", "list_backups", "validate_page", "read_page", "validate_page_fields", "inspect_backups", "check_pagination", "remember_page", "publish"}
	if len(steps) != len(wantNames) {
		return fmt.Errorf("backup workflow must validate every page before its only publish step")
	}
	for i, name := range wantNames {
		step, ok := steps[i].(map[string]any)
		if !ok || len(step) != 1 || step[name] == nil {
			return fmt.Errorf("backup workflow step %d must be %s", i, name)
		}
	}

	// Paths use YAML keys and sequence indices. Exact expressions guard against
	// accidentally counting manual/failed backups or publishing partial inventory.
	contracts := map[string]any{
		"0/initialize/assign/0/project_id":                                   "test-project",
		"0/initialize/assign/1/instance_id":                                  "emisar",
		"0/initialize/assign/2/metric_type":                                  "custom.googleapis.com/emisar/cloudsql/last_automated_backup_timestamp",
		"0/initialize/assign/3/latest_success":                               0,
		"1/list_backups/call":                                                "googleapis.sqladmin.v1.backupRuns.list",
		"1/list_backups/args/project":                                        "${project_id}",
		"1/list_backups/args/instance":                                       "${instance_id}",
		"1/list_backups/args/maxResults":                                     100,
		"1/list_backups/args/pageToken":                                      "${page_token}",
		"1/list_backups/result":                                              "page",
		"2/validate_page/switch/0/condition":                                 `${page.kind != "sql#backupRunsList"}`,
		"2/validate_page/switch/0/steps/0/reject_page/raise":                 "Unexpected Cloud SQL backup inventory response",
		"3/read_page/assign/0/backups":                                       `${default(map.get(page, "items"), [])}`,
		"3/read_page/assign/1/page_token":                                    `${default(map.get(page, "nextPageToken"), "")}`,
		"4/validate_page_fields/switch/0/condition":                          `${get_type(backups) != "list" or get_type(page_token) != "string"}`,
		"4/validate_page_fields/switch/0/steps/0/reject_page_fields/raise":   "Malformed Cloud SQL backup inventory page",
		"5/inspect_backups/for/value":                                        "backup",
		"5/inspect_backups/for/in":                                           "${backups}",
		"5/inspect_backups/for/steps/0/validate_instance/switch/0/condition": `${backup.instance != instance_id}`,
		"5/inspect_backups/for/steps/0/validate_instance/switch/0/steps/0/reject_instance/raise":     "Backup inventory returned a different instance",
		"5/inspect_backups/for/steps/1/select_automated_success/switch/0/condition":                  `${backup.type != "AUTOMATED" or backup.status != "SUCCESSFUL"}`,
		"5/inspect_backups/for/steps/1/select_automated_success/switch/0/next":                       "continue",
		"5/inspect_backups/for/steps/2/parse_completion/assign/0/completed_at":                       "${time.parse(backup.endTime)}",
		"5/inspect_backups/for/steps/3/validate_completion/switch/0/condition":                       "${completed_at <= 0 or completed_at > sys.now()}",
		"5/inspect_backups/for/steps/3/validate_completion/switch/0/steps/0/reject_completion/raise": "Invalid successful backup completion time",
		"5/inspect_backups/for/steps/4/keep_latest/assign/0/latest_success":                          "${math.max(latest_success, completed_at)}",
		"6/check_pagination/switch/0/condition":                                                      `${page_token == ""}`,
		"6/check_pagination/switch/0/next":                                                           "publish",
		"6/check_pagination/switch/1/condition":                                                      "${page_token in seen_tokens or len(seen_tokens) >= 100}",
		"6/check_pagination/switch/1/steps/0/reject_pagination/raise":                                "Cloud SQL backup inventory pagination did not complete",
		"7/remember_page/assign/0/seen_tokens":                                                       "${list.concat(seen_tokens, page_token)}",
		"7/remember_page/next":                                                                       "list_backups",
		"8/publish/call":                                                                             "http.post",
		"8/publish/args/url":                                                                         `${"https://monitoring.googleapis.com/v3/projects/" + project_id + "/timeSeries"}`,
		"8/publish/args/auth/type":                                                                   "OAuth2",
		"8/publish/args/body/timeSeries/0/metric/type":                                               "${metric_type}",
		"8/publish/args/body/timeSeries/0/metric/labels/instance_id":                                 "${instance_id}",
		"8/publish/args/body/timeSeries/0/resource/type":                                             "global",
		"8/publish/args/body/timeSeries/0/resource/labels/project_id":                                "${project_id}",
		"8/publish/args/body/timeSeries/0/metricKind":                                                "GAUGE",
		"8/publish/args/body/timeSeries/0/valueType":                                                 "DOUBLE",
		"8/publish/args/body/timeSeries/0/points/0/interval/endTime":                                 "${time.format(sys.now())}",
		"8/publish/args/body/timeSeries/0/points/0/value/doubleValue":                                "${latest_success}",
	}
	for path, want := range contracts {
		got, err := workflowValue(steps, path)
		if err != nil || !reflect.DeepEqual(got, want) {
			return fmt.Errorf("backup workflow contract %s: got %v, want %v", path, got, want)
		}
	}
	return nil
}

func workflowValue(value any, path string) (any, error) {
	for _, key := range strings.Split(path, "/") {
		switch node := value.(type) {
		case map[string]any:
			var ok bool
			value, ok = node[key]
			if !ok {
				return nil, fmt.Errorf("missing key %s", key)
			}
		case []any:
			index, err := strconv.Atoi(key)
			if err != nil || index < 0 || index >= len(node) {
				return nil, fmt.Errorf("invalid index %s", key)
			}
			value = node[index]
		default:
			return nil, fmt.Errorf("cannot descend into %T", value)
		}
	}
	return value, nil
}
