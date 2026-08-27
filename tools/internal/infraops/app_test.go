package infraops

import (
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestParsePortalOptions(t *testing.T) {
	t.Setenv("EMISAR_GCP_PROJECT", "project-a")
	options, err := parsePortalOptions([]string{
		"--host", "portal-a", "--host", "portal-b", "logs", "--follow",
	})
	if err != nil {
		t.Fatal(err)
	}
	if options.project != "project-a" ||
		!reflect.DeepEqual(options.requested, []string{"portal-a", "portal-b"}) ||
		options.command != "logs" || !options.follow {
		t.Fatalf("unexpected options: %#v", options)
	}
}

func TestParsePortalOptionsRejectsConflicts(t *testing.T) {
	_, err := parsePortalOptions([]string{"--host", "portal-a", "--reuse-last-selection", "status"})
	if err == nil || !IsUsage(err) {
		t.Fatalf("expected usage error, got %v", err)
	}
}

func TestRemotePortalCommandQuotesArguments(t *testing.T) {
	got := remotePortalCommand(portalOptions{
		command:     "cmd",
		commandArgs: []string{"printf", "%s", "it's safe"},
	})
	want := `bash -lc ''\''printf'\'' '\''%s'\'' '\''it'\''\'\'''\''s safe'\'''`
	if got != want {
		t.Fatalf("remote command:\n got: %s\nwant: %s", got, want)
	}
}

func TestParseDatabaseOptions(t *testing.T) {
	options, err := parseDatabaseOptions([]string{
		"--host", "portal-a", "--port", "15433", "--user", "ops@example.com",
		"--psql", "--", "--command=select 1",
	})
	if err != nil {
		t.Fatal(err)
	}
	if options.host != "portal-a" || options.port != 15433 ||
		options.user != "ops@example.com" || !options.psql ||
		!reflect.DeepEqual(options.psqlArgs, []string{"--command=select 1"}) {
		t.Fatalf("unexpected options: %#v", options)
	}
}

func TestUUID5(t *testing.T) {
	if got, want := uuid5("www.widgets.com"), "21f7f8de-8051-5b89-8680-0195ef798b6a"; got != want {
		t.Fatalf("uuid5 = %s, want %s", got, want)
	}
}

func TestPosticoURLQuotesTheIAMUser(t *testing.T) {
	got := posticoURL("project:region:emisar", "ops@example.com", 15432)
	if !strings.HasPrefix(got, "postico://ops%40example.com@127.0.0.1:15432/emisar?") {
		t.Fatalf("Postico URL did not quote IAM user: %s", got)
	}
}

func TestDiscoverDrillIDs(t *testing.T) {
	var inventory drillInventory
	inventory.sql = append(inventory.sql, sqlInstance{Name: "edrill-2607221300-abcdef-db"})
	inventory.vms = append(inventory.vms, computeInstance{
		Name:   "edrill-2607221301-123abc-probe",
		Labels: map[string]string{"drill_id": "edrill-2607221301-123abc"},
	})
	inventory.accounts = append(inventory.accounts, serviceAccount{
		Email: "edrill-2607221300-abcdef@emisar.iam.gserviceaccount.com",
	})
	got := discoverDrillIDs(inventory)
	want := []string{"edrill-2607221300-abcdef", "edrill-2607221301-123abc"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("drill IDs = %v, want %v", got, want)
	}
}

func TestDrillCreatedAt(t *testing.T) {
	got, err := drillCreatedAt("edrill-2607221300-abcdef")
	if err != nil {
		t.Fatal(err)
	}
	want := time.Date(2026, 7, 22, 13, 0, 0, 0, time.UTC)
	if !got.Equal(want) {
		t.Fatalf("created = %s, want %s", got, want)
	}
}

func TestExtractWriteFilesNaming(t *testing.T) {
	document := cloudInitDocument{}
	document.WriteFiles = append(document.WriteFiles, struct {
		Path        string `yaml:"path"`
		Permissions string `yaml:"permissions"`
		Encoding    string `yaml:"encoding"`
		Content     string `yaml:"content"`
	}{Path: "/opt/emisar/example.sh", Content: "echo ok\n"})

	destination := t.TempDir()
	paths, err := extractWriteFiles(document, destination, true, func(string, string) bool { return true })
	if err != nil {
		t.Fatal(err)
	}
	if len(paths) != 1 || filepath.Base(paths[0]) != "example.sh" {
		t.Fatalf("unexpected paths: %v", paths)
	}
	data, err := os.ReadFile(paths[0])
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "echo ok\n" {
		t.Fatalf("unexpected content: %q", data)
	}
}

// An empty write is still a write. Reporting it as "does not write" sends the
// reader hunting for a missing entry that is right there, and the same conflated
// sentinel let two empty writes past the write-once guard.
func TestRequireWriteFileSeparatesAbsenceFromEmptiness(t *testing.T) {
	entry := func(path, content string) struct {
		Path        string `yaml:"path"`
		Permissions string `yaml:"permissions"`
		Encoding    string `yaml:"encoding"`
		Content     string `yaml:"content"`
	} {
		return struct {
			Path        string `yaml:"path"`
			Permissions string `yaml:"permissions"`
			Encoding    string `yaml:"encoding"`
			Content     string `yaml:"content"`
		}{Path: path, Permissions: "0644", Content: content}
	}

	t.Run("an empty write is found", func(t *testing.T) {
		document := cloudInitDocument{}
		document.WriteFiles = append(document.WriteFiles, entry("/opt/emisar/env", ""))
		content, err := requireWriteFile(document, "/opt/emisar/env", "0644")
		if err != nil {
			t.Fatalf("an empty write should be found, got %v", err)
		}
		if content != "" {
			t.Fatalf("content = %q, want empty", content)
		}
	})

	t.Run("two empty writes still trip the write-once guard", func(t *testing.T) {
		document := cloudInitDocument{}
		document.WriteFiles = append(document.WriteFiles,
			entry("/opt/emisar/env", ""), entry("/opt/emisar/env", ""))
		if _, err := requireWriteFile(document, "/opt/emisar/env", "0644"); err == nil ||
			!strings.Contains(err.Error(), "more than once") {
			t.Fatalf("duplicate empty writes error = %v, want more-than-once", err)
		}
	})

	t.Run("a genuinely absent path is still absent", func(t *testing.T) {
		if _, err := requireWriteFile(cloudInitDocument{}, "/opt/emisar/env", "0644"); err == nil ||
			!strings.Contains(err.Error(), "does not write") {
			t.Fatalf("absent path error = %v, want does-not-write", err)
		}
	})
}

func TestTerraformImageRequiresAnImmutableDigest(t *testing.T) {
	path := filepath.Join(t.TempDir(), "images.tf")
	if err := os.WriteFile(path, []byte(`
locals {
  image = "example.invalid/tool:1.2.3@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
`), 0o600); err != nil {
		t.Fatal(err)
	}
	image, err := terraformImage(path, "image")
	if err != nil {
		t.Fatal(err)
	}
	if err := requirePinnedImage(image); err != nil {
		t.Fatal(err)
	}
	if err := requirePinnedImage("example.invalid/tool:1.2.3"); err == nil {
		t.Fatal("mutable image unexpectedly accepted")
	}
	if err := requirePinnedImage(
		"example.invalid:5000/tool@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
	); err == nil {
		t.Fatal("untagged image unexpectedly accepted")
	}
}

func TestParseCloudInitRejectsAliases(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cloud-init.yaml")
	if err := os.WriteFile(path, []byte("write_files:\n  - &file\n    path: /a\n  - *file\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := parseCloudInit(path); err == nil || !strings.Contains(err.Error(), "aliases are not allowed") {
		t.Fatalf("expected alias rejection, got %v", err)
	}
}

func TestPortalHelpDoesNotRequireGcloud(t *testing.T) {
	var out bytes.Buffer
	app := New(t.TempDir(), strings.NewReader(""), &out, &out)
	app.LookPath = func(string) (string, error) {
		t.Fatal("help must not inspect installed commands")
		return "", nil
	}
	if err := app.portal(t.Context(), []string{"--help"}); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "usage: ./run ops portal") {
		t.Fatalf("unexpected help: %s", out.String())
	}
}
