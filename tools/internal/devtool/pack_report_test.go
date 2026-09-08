package devtool

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/andrewdryga/emisar/tools/internal/packtest"
)

func TestRunPackTestJobPersistsFailureBeforeTeardown(t *testing.T) {
	root := t.TempDir()
	packTestDockerLog(t, root)
	t.Setenv("FAIL_RUN", "1")
	reports := filepath.Join(root, "reports")
	path := filepath.Join(reports, "postgres", "uptime.log")
	t.Setenv("EVIDENCE_REPORT", path)
	job := packTestJob{
		InvocationID: "persist-before-down",
		Plan: packtest.PlanRef{
			Name: "postgres", Path: filepath.Join("packs", "postgres", "test", "cases.yaml"),
			Services: []string{"postgres"},
		},
		Case: packtest.CaseRef{ID: "uptime"},
	}
	app := New(root, nil, io.Discard, io.Discard)
	result := app.runPackTestJob(t.Context(), "base.yaml", "fixture-image", reports, job)
	if result.Err == nil || !strings.Contains(result.Err.Error(), "exit status 1") {
		t.Fatalf("case error = %v, want fixture run failure", result.Err)
	}
	if strings.Contains(result.Err.Error(), "cleanup:") {
		t.Fatalf("cleanup did not find persisted evidence: %v", result.Err)
	}
	if !strings.Contains(string(result.Output), "Evidence persisted before teardown") {
		t.Fatalf("cleanup did not verify evidence: %s", result.Output)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != string(result.Output) || !strings.Contains(string(data), "Case duration:") {
		t.Fatalf("persisted report does not match the complete result: %s", data)
	}
}

func TestRunPackTestJobCanceledBeforeStartCreatesNoResources(t *testing.T) {
	root := t.TempDir()
	log := packTestDockerLog(t, root)
	reports := filepath.Join(root, "reports")
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	app := New(root, nil, io.Discard, io.Discard)
	result := app.runPackTestJob(ctx, "base.yaml", "fixture-image", reports, packTestJob{
		Plan: packtest.PlanRef{Name: "postgres"}, Case: packtest.CaseRef{ID: "queued"},
	})
	if !errors.Is(result.Err, context.Canceled) {
		t.Fatalf("result error = %v, want cancellation", result.Err)
	}
	if _, err := os.Stat(log); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("canceled queued case invoked Docker: %v", err)
	}
	data, err := os.ReadFile(filepath.Join(reports, "postgres", "queued.log"))
	if err != nil || !strings.Contains(string(data), "Error: context canceled") {
		t.Fatalf("queued case did not retain its failure report: %s, %v", data, err)
	}
}

type failingReportWriter struct{ err error }

func (w failingReportWriter) Write([]byte) (int, error) { return 0, w.err }

func TestPackTestReportRetainsOutputAndWriteFailure(t *testing.T) {
	failure := errors.New("disk full")
	report := &packTestReport{file: failingReportWriter{err: failure}}
	if _, err := report.Write([]byte("failure evidence")); !errors.Is(err, failure) {
		t.Fatalf("write error = %v", err)
	}
	// A later successful write must not hide the earlier persistence failure.
	report.file = io.Discard
	if _, err := report.Write([]byte("\ncleanup complete")); err != nil {
		t.Fatal(err)
	}
	if !errors.Is(report.err, failure) || report.output.String() != "failure evidence\ncleanup complete" {
		t.Fatalf("lost report failure/output: %v, %s", report.err, report.output.String())
	}
}
