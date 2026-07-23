package packtest

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestExitCodesAcceptScalarAndList(t *testing.T) {
	for _, test := range []struct {
		json string
		code int
		want bool
	}{{"0", 0, true}, {"[0,1]", 1, true}, {"[0,1]", 2, false}} {
		var codes ExitCodes
		if err := json.Unmarshal([]byte(test.json), &codes); err != nil {
			t.Fatal(err)
		}
		if got := codes.accepts(test.code); got != test.want {
			t.Fatalf("%s accepts %d = %v, want %v", test.json, test.code, got, test.want)
		}
	}
}

func TestRunPreservesArgsDefaultsAssertionsAndSkips(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("fixture executable is POSIX shell")
	}
	root := t.TempDir()
	pack := filepath.Join(root, "packs", "example", "test")
	if err := os.MkdirAll(pack, 0o755); err != nil {
		t.Fatal(err)
	}
	cases := `{"defaults":{"env":{"FIXTURE":"present"}},"cases":[
 {"action":"example.ok","args":{"count":3,"name":"demo"},"expect_exit":[0,1],"expect_stdout_contains":["present","count=3","name=demo"]},
 {"action":"example.skipped","skip":"needs a cluster"}
]}`
	if err := os.WriteFile(filepath.Join(pack, "cases.json"), []byte(cases), 0o644); err != nil {
		t.Fatal(err)
	}
	executable := filepath.Join(root, "emisar")
	script := "#!/bin/sh\nprintf '%s\\n' \"$FIXTURE\" \"$@\"\nexit 1\n"
	if err := os.WriteFile(executable, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	totals, err := Run(Config{
		Emisar: executable, PacksDir: filepath.Join(root, "packs"), Config: "test.yaml",
		Reports: filepath.Join(root, "reports"), Out: &output, Err: &output,
		BaseEnv: []string{"FIXTURE=stale"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if totals.Pass != 1 || totals.Skip != 1 || totals.Fail != 0 {
		t.Fatalf("totals = %+v", totals)
	}
	if text := output.String(); !strings.Contains(text, "PASS example.ok") || !strings.Contains(text, "SKIP example.skipped") {
		t.Fatalf("output = %s", text)
	}
}

func TestRunReportsMalformedPack(t *testing.T) {
	root := t.TempDir()
	pack := filepath.Join(root, "packs", "broken", "test")
	if err := os.MkdirAll(pack, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(pack, "cases.json"), []byte("{"), 0o644); err != nil {
		t.Fatal(err)
	}
	executable := filepath.Join(root, "emisar")
	if err := os.WriteFile(executable, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	_, err := Run(Config{Emisar: executable, PacksDir: filepath.Join(root, "packs"), Reports: filepath.Join(root, "reports"), Out: &output, Err: &output})
	if err == nil || !strings.Contains(output.String(), "ERROR broken - parse") {
		t.Fatalf("malformed pack error = %v, output = %q", err, output.String())
	}
}
