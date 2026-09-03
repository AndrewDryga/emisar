package main

import (
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"
)

func TestFetchGitHubPinsHeadersAndPath(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("test fixture is a POSIX executable")
	}

	directory := t.TempDir()
	capture := filepath.Join(directory, "args")
	command := filepath.Join(directory, "gh")
	fixture := "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$CAPTURE\"\nprintf '%s' '{\"ok\":true}'\n"
	if err := os.WriteFile(command, []byte(fixture), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CAPTURE", capture)
	t.Setenv("PATH", directory+string(os.PathListSeparator)+os.Getenv("PATH"))

	got, err := fetchGitHub(t.Context(), "repos/owner/repo/environments/public-releases")
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != `{"ok":true}` {
		t.Fatalf("response = %q", got)
	}
	data, err := os.ReadFile(capture)
	if err != nil {
		t.Fatal(err)
	}
	args := strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
	want := []string{
		"api",
		"-H", "Accept: application/vnd.github+json",
		"-H", "X-GitHub-Api-Version: 2022-11-28",
		"repos/owner/repo/environments/public-releases",
	}
	if !reflect.DeepEqual(args, want) {
		t.Fatalf("arguments = %v, want %v", args, want)
	}
}
