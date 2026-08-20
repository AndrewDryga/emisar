package main

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestAuthImportStoresOwnerOnlyCredentialWithoutEchoingSecret(t *testing.T) {
	configDir, _ := useTestUserConfigDir(t)
	key := testAPIKey(71)
	var stdout, stderr bytes.Buffer

	if code := runAuthCommand([]string{"import", testEndpointOrigin}, strings.NewReader(key+"\n"), &stdout, &stderr); code != 0 {
		t.Fatalf("import exit=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
	if strings.Contains(stdout.String(), key) || strings.Contains(stderr.String(), key) {
		t.Fatal("credential import echoed the API key")
	}

	store := newCLICredentialStoreAt(configDir, testEndpointOrigin, keyPrefix(key))
	state, err := store.load("")
	if err != nil {
		t.Fatalf("load imported state: %v", err)
	}
	if state.Current != key || state.EndpointOrigin != testEndpointOrigin || state.Pending != "" {
		t.Fatalf("imported state = %#v", state)
	}
	if filepath.Base(store.path) != cliCredentialFilename {
		t.Fatalf("CLI credential path = %q", store.path)
	}
	if runtime.GOOS != "windows" {
		assertMode(t, store.path, 0o600)
		assertMode(t, filepath.Dir(store.path), 0o700)
	}

	stdout.Reset()
	stderr.Reset()
	if code := runAuthCommand([]string{"status", testEndpointOrigin}, strings.NewReader(""), &stdout, &stderr); code != 0 {
		t.Fatalf("status exit=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
	if !strings.Contains(stdout.String(), "Credential stored for "+testEndpointOrigin) || stderr.Len() != 0 {
		t.Fatalf("status stdout=%q stderr=%q", stdout.String(), stderr.String())
	}
	if strings.Contains(stdout.String(), key) {
		t.Fatal("auth status disclosed the API key")
	}
}

func TestMainAuthImportThenDirectCLIEndToEnd(t *testing.T) {
	_, configEnv := useTestUserConfigDir(t)
	key := testAPIKey(77)
	var authorization string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authorization = r.Header.Get("Authorization")
		writeCLIResult(t, w, r, `{"tools":[]}`)
	}))
	defer srv.Close()

	stdout, stderr, code := runMain(t, key+"\n", []string{"auth", "import", srv.URL}, configEnv)
	if code != 0 || !strings.Contains(stdout, "Credential stored for "+srv.URL) || stderr != "" {
		t.Fatalf("import exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	if strings.Contains(stdout, key) || strings.Contains(stderr, key) {
		t.Fatal("process-level import echoed the API key")
	}

	stdout, stderr, code = runMain(t, "", []string{"list_tools", "--json"}, configEnv)
	if code != 0 || strings.TrimSpace(stdout) != "[]" || stderr != "" {
		t.Fatalf("list_tools exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	if authorization != "Bearer "+key {
		t.Fatalf("Authorization = %q", authorization)
	}
}

func TestAuthImportWarnsWhenReplacingWithoutDisclosingEitherKey(t *testing.T) {
	useTestUserConfigDir(t)
	oldKey := testAPIKey(81)
	newKey := testAPIKey(82)
	var stdout, stderr bytes.Buffer
	if code := runAuthCommand([]string{"import", testEndpointOrigin}, strings.NewReader(oldKey), &stdout, &stderr); code != 0 {
		t.Fatalf("first import exit=%d stderr=%q", code, stderr.String())
	}

	stdout.Reset()
	stderr.Reset()
	if code := runAuthCommand([]string{"import", testEndpointOrigin}, strings.NewReader(newKey), &stdout, &stderr); code != 0 {
		t.Fatalf("replacement exit=%d stderr=%q", code, stderr.String())
	}
	if !strings.Contains(stderr.String(), "replaced the stored CLI credential") ||
		!strings.Contains(stderr.String(), testEndpointOrigin+"/app/agents") {
		t.Fatalf("replacement warning = %q", stderr.String())
	}
	for _, secret := range []string{oldKey, newKey} {
		if strings.Contains(stdout.String(), secret) || strings.Contains(stderr.String(), secret) {
			t.Fatal("replacement disclosed an API key")
		}
	}

	stdout.Reset()
	stderr.Reset()
	otherOrigin := "https://other.example"
	if code := runAuthCommand([]string{"import", otherOrigin}, strings.NewReader(newKey), &stdout, &stderr); code != 0 {
		t.Fatalf("endpoint replacement exit=%d stderr=%q", code, stderr.String())
	}
	if !strings.Contains(stderr.String(), testEndpointOrigin+"/app/agents") {
		t.Fatalf("endpoint replacement warning = %q", stderr.String())
	}
}

func TestAuthHelpAndUsageDoNotRequireConfiguration(t *testing.T) {
	stdout, stderr, code := runMain(t, "", []string{"auth", "--help"}, nil)
	if code != 0 || stdout != authHelpText || stderr != "" {
		t.Fatalf("help exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}

	secret := testAPIKey(78)
	stdout, stderr, code = runMain(t, "", []string{"auth", "import", testEndpointOrigin, secret}, nil)
	if code != 2 || stdout != "" || stderr != authUsageText {
		t.Fatalf("usage exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	if strings.Contains(stderr, secret) {
		t.Fatal("invalid auth invocation echoed an argv secret")
	}
}

func TestAuthImportRejectsUnsafeCredentialPath(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlink creation requires privileges on Windows")
	}
	configDir, _ := useTestUserConfigDir(t)
	dir := filepath.Join(configDir, "emisar", "credentials")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(t.TempDir(), "target")
	if err := os.WriteFile(target, []byte("leave me\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(dir, cliCredentialFilename)); err != nil {
		t.Fatal(err)
	}

	key := testAPIKey(72)
	var stdout, stderr bytes.Buffer
	code := runAuthCommand([]string{"import", testEndpointOrigin}, strings.NewReader(key), &stdout, &stderr)
	if code != 1 || stdout.Len() != 0 || !strings.Contains(stderr.String(), "not a regular file") {
		t.Fatalf("exit=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
	if strings.Contains(stderr.String(), key) {
		t.Fatal("unsafe-path error disclosed the API key")
	}
	data, err := os.ReadFile(target)
	if err != nil || string(data) != "leave me\n" {
		t.Fatalf("symlink target changed: data=%q err=%v", data, err)
	}
}

func TestAuthImportRejectsInvalidAndOversizedInput(t *testing.T) {
	useTestUserConfigDir(t)
	for _, input := range []string{"not-a-key", strings.Repeat("x", maxCredentialInputBytes+1)} {
		var stdout, stderr bytes.Buffer
		code := runAuthCommand([]string{"import", testEndpointOrigin}, strings.NewReader(input), &stdout, &stderr)
		if code != 1 || stdout.Len() != 0 || stderr.Len() == 0 {
			t.Errorf("input length %d: exit=%d stdout=%q stderr=%q", len(input), code, stdout.String(), stderr.String())
		}
		if strings.Contains(stderr.String(), input) {
			t.Errorf("input length %d was echoed", len(input))
		}
	}
}

func TestStoredCLICredentialFailsClosedOnUnsafeState(t *testing.T) {
	tests := []struct {
		name    string
		content string
		mode    os.FileMode
		want    string
	}{
		{"malformed JSON", "{nope\n", 0o600, "decode credential state"},
		{"multiple values", "{} {}\n", 0o600, "decode credential state"},
		{"oversized", strings.Repeat("x", maxCredentialStateBytes+1), 0o600, "limit is"},
		{"unsafe mode", "{}\n", 0o644, "want owner-only"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if runtime.GOOS == "windows" && test.name == "unsafe mode" {
				t.Skip("Windows does not expose Unix permission bits")
			}
			configDir, _ := useTestUserConfigDir(t)
			store := newCLICredentialStoreAt(configDir, "", "")
			if err := os.MkdirAll(filepath.Dir(store.path), 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(store.path, []byte(test.content), test.mode); err != nil {
				t.Fatal(err)
			}
			if err := os.Chmod(store.path, test.mode); err != nil {
				t.Fatal(err)
			}

			var stdout, stderr bytes.Buffer
			code := runAuthCommand(nil, strings.NewReader(""), &stdout, &stderr)
			if code != 1 || stdout.Len() != 0 || !strings.Contains(stderr.String(), test.want) {
				t.Fatalf("exit=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
			}
		})
	}
}

func TestDirectCLIUsesStoredCredentialButStdioDoesNot(t *testing.T) {
	configDir, configEnv := useTestUserConfigDir(t)
	key := testAPIKey(73)
	var authorization string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authorization = r.Header.Get("Authorization")
		writeCLIResult(t, w, r, `{"tools":[]}`)
	}))
	defer srv.Close()

	store := newCLICredentialStoreAt(configDir, srv.URL, keyPrefix(key))
	state := credentialState{
		Version:         credentialStateVersion,
		EndpointOrigin:  srv.URL,
		BootstrapPrefix: keyPrefix(key),
		Current:         key,
	}
	if err := store.persist(state); err != nil {
		t.Fatal(err)
	}

	stdout, stderr, code := runMain(t, "", []string{"list_tools", "--json"}, configEnv)
	if code != 0 || strings.TrimSpace(stdout) != "[]" || stderr != "" {
		t.Fatalf("direct CLI exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	if authorization != "Bearer "+key {
		t.Fatalf("Authorization = %q", authorization)
	}

	stdout, stderr, code = runMain(t, "", nil, configEnv)
	if code != 1 || stdout != "" || !strings.Contains(stderr, "EMISAR_URL and EMISAR_API_KEY must both be set") {
		t.Fatalf("stdio exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
}

func TestDirectCLIExplicitEnvironmentOverridesStoredCredential(t *testing.T) {
	configDir, configEnv := useTestUserConfigDir(t)
	storedKey := testAPIKey(74)
	storedStore := newCLICredentialStoreAt(configDir, testEndpointOrigin, keyPrefix(storedKey))
	if err := storedStore.persist(credentialState{
		Version:         credentialStateVersion,
		EndpointOrigin:  testEndpointOrigin,
		BootstrapPrefix: keyPrefix(storedKey),
		Current:         storedKey,
	}); err != nil {
		t.Fatal(err)
	}

	explicitKey := "explicit-bearer"
	var authorization string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authorization = r.Header.Get("Authorization")
		writeCLIResult(t, w, r, `{"tools":[]}`)
	}))
	defer srv.Close()
	configEnv["EMISAR_URL"] = srv.URL
	configEnv["EMISAR_API_KEY"] = explicitKey

	_, stderr, code := runMain(t, "", []string{"list_tools"}, configEnv)
	if code != 0 || stderr != "" {
		t.Fatalf("exit=%d stderr=%q", code, stderr)
	}
	if authorization != "Bearer "+explicitKey {
		t.Fatalf("Authorization = %q, stored credential overrode explicit env", authorization)
	}
}

func TestDirectCLINeverCompletesPartialEnvironmentFromStoredCredential(t *testing.T) {
	configDir, configEnv := useTestUserConfigDir(t)
	key := testAPIKey(75)
	store := newCLICredentialStoreAt(configDir, testEndpointOrigin, keyPrefix(key))
	if err := store.persist(credentialState{
		Version:         credentialStateVersion,
		EndpointOrigin:  testEndpointOrigin,
		BootstrapPrefix: keyPrefix(key),
		Current:         key,
	}); err != nil {
		t.Fatal(err)
	}

	for name, override := range map[string]map[string]string{
		"URL only":       {"EMISAR_URL": testEndpointOrigin},
		"key only":       {"EMISAR_API_KEY": key},
		"empty URL":      {"EMISAR_URL": ""},
		"whitespace key": {"EMISAR_API_KEY": " \n"},
	} {
		t.Run(name, func(t *testing.T) {
			env := copyStringMap(configEnv)
			for key, value := range override {
				env[key] = value
			}
			stdout, stderr, code := runMain(t, "", []string{"list_tools"}, env)
			if code != 1 || stdout != "" || !strings.Contains(stderr, "must be set") {
				t.Fatalf("exit=%d stdout=%q stderr=%q", code, stdout, stderr)
			}
		})
	}
}

func TestStoredCLICredentialKeepsRotationInNamedState(t *testing.T) {
	configDir, _ := useTestUserConfigDir(t)
	key := testAPIKey(76)
	store := newCLICredentialStoreAt(configDir, testEndpointOrigin, keyPrefix(key))
	if err := store.persist(credentialState{
		Version:         credentialStateVersion,
		EndpointOrigin:  testEndpointOrigin,
		BootstrapPrefix: keyPrefix(key),
		Current:         key,
	}); err != nil {
		t.Fatal(err)
	}

	b, err := newBridgeFromEnv("emisar-mcp-cli", true, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	if b.credentialStore == nil || b.credentialStore.path != store.path {
		t.Fatalf("bridge credential store = %#v, want %s", b.credentialStore, store.path)
	}
	prefix, hash := b.rotationProposal()
	if prefix == "" || hash == "" {
		t.Fatal("stored CLI credential did not prepare a rotation")
	}
	loaded, err := store.load("")
	if err != nil {
		t.Fatal(err)
	}
	if loaded.Current != key || loaded.Pending == "" || keyPrefix(loaded.Pending) != prefix {
		t.Fatalf("rotated state = %#v", loaded)
	}
}

func useTestUserConfigDir(t *testing.T) (string, map[string]string) {
	t.Helper()
	root := t.TempDir()
	env := map[string]string{}
	switch runtime.GOOS {
	case "windows":
		t.Setenv("APPDATA", root)
		env["APPDATA"] = root
	case "darwin":
		t.Setenv("HOME", root)
		env["HOME"] = root
		root = filepath.Join(root, "Library", "Application Support")
	default:
		t.Setenv("XDG_CONFIG_HOME", root)
		env["XDG_CONFIG_HOME"] = root
	}
	t.Setenv("EMISAR_URL", "")
	_ = os.Unsetenv("EMISAR_URL")
	t.Setenv("EMISAR_API_KEY", "")
	_ = os.Unsetenv("EMISAR_API_KEY")
	t.Setenv("EMISAR_ALLOW_INSECURE", "")
	return root, env
}

func assertMode(t *testing.T, path string, want os.FileMode) {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != want {
		t.Fatalf("%s mode = %04o, want %04o", path, info.Mode().Perm(), want)
	}
}

func copyStringMap(source map[string]string) map[string]string {
	copy := make(map[string]string, len(source))
	for key, value := range source {
		copy[key] = value
	}
	return copy
}
