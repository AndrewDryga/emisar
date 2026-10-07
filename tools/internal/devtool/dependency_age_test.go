package devtool

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestDependencyAgeReviewBase(t *testing.T) {
	for _, tc := range []struct {
		name       string
		reviewBase string
		rest       []string
		want       string
		fail       bool
	}{
		{name: "review uses resolved commit", reviewBase: "0123456789abcdef", want: "--base\n0123456789abcdef\n"},
		{name: "standalone preserves explicit base", rest: []string{"--base", "topic-base"}, want: "--base\ntopic-base\n"},
		{name: "standalone preserves defaults"},
		{name: "review propagates failed check", reviewBase: "0123456789abcdef", want: "--base\n0123456789abcdef\n", fail: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			app := testApp(t)
			app.reviewBase = tc.reviewBase
			dir := filepath.Join(app.Root, "tools")
			if err := os.MkdirAll(dir, 0755); err != nil {
				t.Fatal(err)
			}
			capture := filepath.Join(app.Root, "arguments")
			script := "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$TEST_DEP_ARGS\"\nexit \"$TEST_DEP_EXIT\"\n"
			if err := os.WriteFile(filepath.Join(dir, "go"), []byte(script), 0755); err != nil {
				t.Fatal(err)
			}
			t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
			t.Setenv("TEST_DEP_ARGS", capture)
			t.Setenv("TEST_DEP_EXIT", "0")
			if tc.fail {
				t.Setenv("TEST_DEP_EXIT", "2")
			}
			// An unrelated ambient base must not override the resolved review base.
			t.Setenv("DEP_AGE_BASE_REF", "missing-origin-main")
			err := app.depAgeCheck(context.Background(), tc.rest)
			if (err != nil) != tc.fail {
				t.Fatalf("error = %v, want failure %v", err, tc.fail)
			}
			got, err := os.ReadFile(capture)
			if err != nil {
				t.Fatal(err)
			}
			want := "run\n./cmd/depgate\ncheck\n" + tc.want
			if string(got) != want {
				t.Fatalf("arguments = %q, want %q", got, want)
			}
			if os.Getenv("DEP_AGE_BASE_REF") != "missing-origin-main" {
				t.Fatal("changed ambient dependency baseline")
			}
		})
	}
}
