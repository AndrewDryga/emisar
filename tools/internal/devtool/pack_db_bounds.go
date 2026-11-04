package devtool

import (
	"fmt"
	"os"
	"strings"

	"go.yaml.in/yaml/v3"
)

// The runner enforces an action's timeout by killing the client. A database does
// not notice that while it waits on a lock or runs a statement: four timed-out
// postgres.largest_tables_full runs during a held lock left four backends holding
// connection slots until the lock cleared, and MySQL's lock_wait_timeout defaults
// to a year. So an action that runs a client names its limits in its own program,
// where the server enforces them.
// .agent/kb/rules/packs-reads-bound-their-work-on-the-target.md
var packDBClientLimits = map[string][]string{
	"psql":  {"statement_timeout", "lock_timeout"},
	"mysql": {"lock_wait_timeout", "max_execution_time", "max_statement_time"},
}

// Each entry says why the server-side limit does not apply. The maintenance
// statements run for hours by design, and VACUUM and REINDEX CONCURRENTLY refuse to
// run inside the transaction a limit is set in. The others call one function or
// statement that holds no lock on application data.
var packDBBoundExemptActions = map[string]string{
	"postgres.analyze_table":            "maintenance with a 30m timeout",
	"postgres.reindex_concurrent":       "maintenance with a 4h timeout; refuses a transaction",
	"postgres.vacuum_table":             "maintenance with a 2h timeout; refuses a transaction",
	"postgres.cancel_query":             "one function call, no relation lock",
	"postgres.kill_idle":                "one function call per idle backend, no relation lock",
	"postgres.terminate_backend":        "one function call, no relation lock",
	"postgres.reload_conf":              "one function call, no relation lock",
	"postgres.pg_stat_statements_reset": "one function call, no relation lock",
	"mysql.analyze_table":               "maintenance with a 5m timeout",
	"mysql.optimize_table":              "maintenance with a 1h timeout",
	"mysql.flush_logs":                  "one statement, no application data",
	"mysql.flush_status":                "one statement, no application data",
	"mysql.kill_connection":             "one statement, no application data",
	"mysql.kill_query":                  "one statement, no application data",
}

type packDBBoundAction struct {
	ID        string `yaml:"id"`
	Execution struct {
		Command struct {
			Binary string   `yaml:"binary"`
			Argv   []string `yaml:"argv"`
		} `yaml:"command"`
		Env map[string]string `yaml:"env"`
	} `yaml:"execution"`
}

func validatePackDBReadBounds(input packActionLintInput) error {
	var failures []string
	for _, path := range input.actionPaths {
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		var action packDBBoundAction
		if err := yaml.Unmarshal(data, &action); err != nil {
			return fmt.Errorf("parse %s: %w", path, err)
		}
		// A startup option depends on what sits between the action and the server.
		// PgBouncer refuses an unknown one by default, and before 1.26 one that
		// ignores the options parameter drops it in silence: a read-only option set
		// this way let a query write.
		if _, set := action.Execution.Env["PGOPTIONS"]; set {
			failures = append(failures, fmt.Sprintf("%s (PGOPTIONS, which a pooler can refuse or drop; use SET LOCAL in the program)", action.ID))
		}
		if _, exempt := packDBBoundExemptActions[action.ID]; exempt {
			continue
		}
		program := strings.Join(action.Execution.Command.Argv, "\n")
		for client, limits := range packDBClientLimits {
			if !packDBActionRunsClient(action.Execution.Command.Binary, program, client) {
				continue
			}
			for _, limit := range limits {
				if !strings.Contains(program, limit) {
					failures = append(failures, fmt.Sprintf("%s (%s without %s)", action.ID, client, limit))
				}
			}
		}
	}
	if len(failures) > 0 {
		return fmt.Errorf(
			"an action running a database client must set its limits on the server, because killing the client does not stop the statement: %s",
			strings.Join(failures, ", "),
		)
	}
	return nil
}

func packDBActionRunsClient(binary, program, client string) bool {
	if binary == client {
		return true
	}
	if binary != "/bin/sh" {
		return false
	}
	return strings.Contains(program, client+" ")
}
