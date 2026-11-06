package infraops

import (
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
)

// LoggerJSON's GoogleCloud formatter writes a Logger message verbatim to
// jsonPayload.message, where a Cloud Logging `=` term compares the whole value
// and a `:` term finds a substring. A term no portal line spells is an alert
// that can never fire, and `=` never matches a message that embeds an id.
func TestApplicationLogMetricsCountEmittedLines(t *testing.T) {
	root := repositoryRoot(t)
	emitted := emittedPortalLogMessages(t, root)
	filters := applicationLogMetricFilters(t, root)
	for key, filter := range filters {
		for _, term := range messageTerm.FindAllStringSubmatch(filter, -1) {
			if !slices.ContainsFunc(emitted, func(message string) bool { return termMatches(term, message) }) {
				t.Errorf("%s counts %s, which no portal line emits", key, term[0])
			}
		}
	}

	// A sweep rescues a raising row so its tick carries on, so the executor
	// never logs recurrent_job.failed for it: the row line must be counted itself.
	recurrent := messageTerm.FindAllStringSubmatch(filters["recurrent_job_failures"], -1)
	rows := 0
	for _, message := range emitted {
		if !strings.HasPrefix(message, "sweep.row_failed ") {
			continue
		}
		rows++
		if !slices.ContainsFunc(recurrent, func(term []string) bool { return termMatches(term, message) }) {
			t.Errorf("recurrent_job_failures does not count the rescued sweep row line %q", message)
		}
	}
	if rows == 0 {
		t.Fatal("found no rescued sweep row emitter")
	}
}

var messageTerm = regexp.MustCompile(`jsonPayload\.message([=:])"([^"]*)"`)

func termMatches(term []string, message string) bool {
	if term[1] == "=" {
		return message == term[2]
	}
	return strings.Contains(message, term[2])
}

func applicationLogMetricFilters(t *testing.T, root string) map[string]string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(root, "infra/monitoring_application.tf"))
	if err != nil {
		t.Fatal(err)
	}
	block := regexp.MustCompile(`(?ms)^  application_log_metrics = \{$.*?^  \}$`).Find(data)
	filters := map[string]string{}
	for _, metric := range regexp.MustCompile(`(?ms)^    (\w+) = \{$.*?^      filter\s+= "(.*?)"$`).FindAllSubmatch(block, -1) {
		filters[string(metric[1])] = strings.ReplaceAll(string(metric[2]), `\"`, `"`)
	}
	if filters["recurrent_job_failures"] == "" {
		t.Fatalf("application log metric filters are unreadable: %v", filters)
	}
	return filters
}

// Each interpolation becomes a sample value, as `row=#{row.id}` does at runtime.
func emittedPortalLogMessages(t *testing.T, root string) []string {
	t.Helper()
	call := regexp.MustCompile(`Logger\.(?:debug|info|notice|warning|error|critical|alert|emergency)\(\s*"((?:[^"\\]|\\.)*)"`)
	interpolation := regexp.MustCompile(`#\{[^}]*\}`)
	libs, _ := filepath.Glob(filepath.Join(root, "portal/apps/*/lib"))
	if len(libs) == 0 {
		t.Fatal("found no portal application sources")
	}
	var messages []string
	for _, lib := range libs {
		err := filepath.WalkDir(lib, func(path string, entry fs.DirEntry, err error) error {
			if err != nil || entry.IsDir() || filepath.Ext(path) != ".ex" {
				return err
			}
			source, err := os.ReadFile(path)
			for _, match := range call.FindAllSubmatch(source, -1) {
				messages = append(messages, interpolation.ReplaceAllString(string(match[1]), "0"))
			}
			return err
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	return messages
}
