package ci

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"go.yaml.in/yaml/v3"
)

func TestMCPRegistryLatestBeyondFirstHistoryPage(t *testing.T) {
	for _, tool := range []string{"bash", "curl", "jq"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skipf("%s is required to exercise the publication scripts: %v", tool, err)
		}
	}
	data, err := os.ReadFile(filepath.Join("..", "..", "..", ".github", "workflows", "mcp-registry-release.yml"))
	if err != nil {
		t.Fatal(err)
	}
	var workflow struct {
		Jobs map[string]struct {
			Steps []struct {
				Name string
				Run  string
			}
		}
	}
	if err := yaml.Unmarshal(data, &workflow); err != nil {
		t.Fatal(err)
	}
	// The registry's default first page holds 30 versions; the latest can be
	// beyond it. Its documented version=latest filter selects before pagination.
	var history []map[string]any
	for minor := 21; minor <= 51; minor++ {
		history = append(history, map[string]any{
			"server": map[string]any{"name": "dev.emisar/emisar", "version": fmt.Sprintf("0.%d.0", minor)},
			"_meta":  map[string]any{"io.modelcontextprotocol.registry/official": map[string]any{"isLatest": minor == 51}},
		})
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path == "/healthz" {
			_, _ = w.Write([]byte(`{"status":"ok","version":"0.51.0"}`))
			return
		}
		if r.URL.Path != "/v0/servers" || r.URL.Query().Get("search") != "dev.emisar/emisar" {
			http.Error(w, "unexpected registry lookup", http.StatusBadRequest)
			return
		}
		entries, cursor := history[:30], "dev.emisar/emisar:0.50.0"
		if r.URL.Query().Get("version") == "latest" {
			entries, cursor = history[30:], ""
		}
		if err := json.NewEncoder(w).Encode(map[string]any{
			"servers": entries, "metadata": map[string]any{"count": len(entries), "nextCursor": cursor},
		}); err != nil {
			t.Error(err)
		}
	}))
	defer server.Close()
	for _, test := range []struct{ job, step, want string }{
		{"reconcile", "Decide what the registry should list", "publish=false"},
		{"publish", "Verify the live listing", "Registry lists 0.51.0 as latest."},
	} {
		t.Run(test.job, func(t *testing.T) {
			var script string
			for _, step := range workflow.Jobs[test.job].Steps {
				if step.Name == test.step {
					script = step.Run
				}
			}
			if script == "" {
				t.Fatalf("publication step %q is missing", test.step)
			}
			script = strings.ReplaceAll(script, "https://emisar.dev/healthz", server.URL+"/healthz")
			script = strings.ReplaceAll(script, "https://registry.modelcontextprotocol.io", server.URL)
			root := t.TempDir()
			// A missing latest lookup should fail immediately, not spend the real
			// publication's three-minute convergence budget in a unit test.
			if err := os.WriteFile(filepath.Join(root, "sleep"), []byte("#!/bin/sh\nexit 1\n"), 0o755); err != nil {
				t.Fatal(err)
			}
			result := filepath.Join(root, "result")
			ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
			defer cancel()
			command := exec.CommandContext(ctx, "bash", "-c", script)
			command.Env = append(os.Environ(), "FORCED_TAG=", "LISTING_VERSION=0.51.0",
				"GITHUB_STEP_SUMMARY="+result, "GITHUB_OUTPUT="+result, "PATH="+root+string(os.PathListSeparator)+os.Getenv("PATH"))
			command.WaitDelay = time.Second
			if output, err := command.CombinedOutput(); err != nil {
				t.Fatalf("publication script: %v\n%s", err, output)
			}
			output, err := os.ReadFile(result)
			if err != nil || !strings.Contains(string(output), test.want) {
				t.Fatalf("publication result = %s, %v; want %q", output, err, test.want)
			}
		})
	}
}
