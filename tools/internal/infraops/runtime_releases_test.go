package infraops

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Lines in the shape builds.hex.pm publishes (read from the live lists on
// 2026-10-04): `<label> <commit> <published-at> <sha256>`, release candidates
// and branch builds included.
var (
	otpBuildLines = []string{
		"OTP-28.5.0.7 aa 2026-09-22T09:00:00Z cc",
		"OTP-29.0.6 e07fd07837e5aa845657f5fa340637121e451d47 2026-09-01T12:13:05Z 3217ee",
		"OTP-29.1 751f87b703fe5948607d08e82599ce644b772e76 2026-09-16T11:12:00Z 008e2d",
		"OTP-29.1.1 ad05823719d77c8faee87348ea39513d4e2f99c5 2026-09-22T08:11:48Z 35186b",
		"OTP-30.0-rc1 bb 2026-09-30T10:00:00Z dd",
		"maint ee 2026-10-03T10:00:00Z ff",
		"",
	}
	elixirBuildLines = []string{
		"v1.20.3-otp-29 6efe0fc 2026-08-04T14:49:25Z 51f799",
		"v1.20.4-otp-29 759443e 2026-08-28T10:07:51Z 7863c5",
		"v1.20.5-otp-28 aa 2026-09-30T10:00:00Z bb",
		"v1.21.0-rc.0-otp-29 cc 2026-09-30T10:00:00Z dd",
		"main-otp-29 ee 2026-10-03T10:00:00Z ff",
	}
)

func TestRuntimeReleaseFindings(t *testing.T) {
	for _, test := range []struct {
		name         string
		erlang       string
		elixir       string
		otp, elixirs []string
		findings     []string
		notes        []string
	}{
		{
			name:   "pins on the newest release of their lines pass; candidates and branches are not releases",
			erlang: "29.1.1", elixir: "1.20.4-otp-29",
			otp: otpBuildLines, elixirs: elixirBuildLines,
		},
		{
			// The incident: 29.1.1 fixed a critical TLS bypass while 29.0.6 was
			// pinned, and no 29.0.x patch ever came. A newer minor of the same
			// major is the release to take.
			name:   "a newer release of the pinned OTP major fails, across a minor",
			erlang: "29.0.6", elixir: "1.20.4-otp-29",
			otp: otpBuildLines, elixirs: elixirBuildLines,
			findings: []string{"Erlang/OTP 29.1.1 (published 2026-09-22) is newer than the pinned erlang 29.0.6"},
		},
		{
			name:   "a newer Elixir patch for the pinned OTP fails",
			erlang: "29.1.1", elixir: "1.20.4-otp-29",
			otp: otpBuildLines,
			elixirs: append(append([]string(nil), elixirBuildLines...),
				"v1.20.5-otp-29 aa 2026-10-02T10:00:00Z bb"),
			findings: []string{"Elixir 1.20.5 (published 2026-10-02) is newer than the pinned elixir 1.20.4-otp-29"},
		},
		{
			name:   "a new OTP major or Elixir minor is an upgrade to plan, not a failure",
			erlang: "29.1.1", elixir: "1.20.4-otp-29",
			otp: append(append([]string(nil), otpBuildLines...),
				"OTP-30.0 aa 2026-10-01T10:00:00Z bb"),
			elixirs: append(append([]string(nil), elixirBuildLines...),
				"v1.21.0-otp-29 aa 2026-10-01T10:00:00Z bb"),
			notes: []string{
				"Erlang/OTP 30.0 opens a new major; plan that upgrade separately",
				"Elixir 1.21.0 opens a new minor line; plan that upgrade separately",
			},
		},
		{
			name:   "four-number OTP releases compare by every number",
			erlang: "28.5.0.6", elixir: "1.20.4-otp-29",
			otp: otpBuildLines, elixirs: elixirBuildLines,
			findings: []string{"Erlang/OTP 28.5.0.7 (published 2026-09-22) is newer than the pinned erlang 28.5.0.6"},
			notes:    []string{"Erlang/OTP 29.1.1 opens a new major; plan that upgrade separately"},
		},
		{
			name:   "29.1 and 29.1.0 are one release",
			erlang: "29.1.0", elixir: "1.20.4-otp-29",
			otp: []string{"OTP-29.1 aa 2026-09-16T11:12:00Z bb"}, elixirs: elixirBuildLines,
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			findings, notes, err := runtimeReleaseFindings(test.erlang, test.elixir, test.otp, test.elixirs)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if strings.Join(findings, "\n") != strings.Join(test.findings, "\n") {
				t.Fatalf("findings:\n got %q\nwant %q", findings, test.findings)
			}
			if strings.Join(notes, "\n") != strings.Join(test.notes, "\n") {
				t.Fatalf("notes:\n got %q\nwant %q", notes, test.notes)
			}
		})
	}
}

func TestRuntimeReleaseFindingsRefusesWhatItCannotJudge(t *testing.T) {
	for _, test := range []struct{ name, erlang, elixir, want string }{
		{"an erlang pin that is not a release", "ref:maint", "1.20.4-otp-29", "erlang pin"},
		{"an elixir pin without its OTP suffix", "29.1.1", "1.20.4", "elixir pin"},
		{"a major the list does not carry", "31.0", "1.20.4-otp-29", "no release of the pinned major 31"},
		{"an Elixir line not built for the pinned OTP", "29.1.1", "1.19.5-otp-29", "no 1.19 release built for OTP 29"},
	} {
		t.Run(test.name, func(t *testing.T) {
			_, _, err := runtimeReleaseFindings(test.erlang, test.elixir, otpBuildLines, elixirBuildLines)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want one containing %q", err, test.want)
			}
		})
	}
}

func TestVerifyRuntimeReleases(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case otpBuildsPath:
			_, _ = w.Write([]byte(strings.Join(otpBuildLines, "\n")))
		case elixirBuildsPath:
			_, _ = w.Write([]byte(strings.Join(elixirBuildLines, "\n")))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	run := func(t *testing.T, toolVersions string) (string, error) {
		t.Helper()
		root := t.TempDir()
		if err := os.WriteFile(filepath.Join(root, ".tool-versions"), []byte(toolVersions), 0o644); err != nil {
			t.Fatal(err)
		}
		var out bytes.Buffer
		app := New(root, strings.NewReader(""), &out, &out)
		app.HexBuilds = server.URL
		err := app.Run(context.Background(), []string{"verify-runtime-releases"})
		return out.String(), err
	}

	t.Run("current pins pass", func(t *testing.T) {
		out, err := run(t, "# toolchain\nerlang 29.1.1\nelixir 1.20.4-otp-29\ngolang 1.27.1\n")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if !strings.Contains(out, "runtime pins are current: erlang 29.1.1, elixir 1.20.4-otp-29") {
			t.Fatalf("output = %q", out)
		}
	})

	t.Run("a stale OTP pin fails and names the release to move to", func(t *testing.T) {
		_, err := run(t, "erlang 29.0.6\nelixir 1.20.4-otp-29\n")
		if err == nil || !strings.Contains(err.Error(), "Erlang/OTP 29.1.1 (published 2026-09-22)") {
			t.Fatalf("error = %v", err)
		}
	})

	t.Run("an unreachable build list is an error, never a pass", func(t *testing.T) {
		root := t.TempDir()
		if err := os.WriteFile(filepath.Join(root, ".tool-versions"),
			[]byte("erlang 29.1.1\nelixir 1.20.4-otp-29\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		var out bytes.Buffer
		app := New(root, strings.NewReader(""), &out, &out)
		app.HexBuilds = server.URL + "/missing"
		if err := app.Run(context.Background(), []string{"verify-runtime-releases"}); err == nil {
			t.Fatal("a missing build list passed")
		}
	})
}
