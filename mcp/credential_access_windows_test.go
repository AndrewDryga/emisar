//go:build windows

package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

func TestCredentialStore_WindowsACLsAreOwnerOnly(t *testing.T) {
	current := testAPIKey(101)
	store := newCredentialStoreAt(t.TempDir(), testEndpointOrigin, keyPrefix(current))
	if err := store.persist(testCredentialState(current, "")); err != nil {
		t.Fatalf("persist: %v", err)
	}
	if err := validateCredentialFileAccess(store.path, nil); err != nil {
		t.Fatalf("credential file ACL: %v", err)
	}
	if err := validateCredentialDirectoryAccess(filepath.Dir(store.path), nil); err != nil {
		t.Fatalf("credential directory ACL: %v", err)
	}
}

func TestCredentialStore_WindowsRejectsBroadFileACL(t *testing.T) {
	current := testAPIKey(102)
	store := newCredentialStoreAt(t.TempDir(), testEndpointOrigin, keyPrefix(current))
	if err := store.persist(testCredentialState(current, "")); err != nil {
		t.Fatalf("persist: %v", err)
	}
	grantWindowsCredentialReadToEveryone(t, store.path, false)

	_, err := store.load(current)
	if err == nil || !strings.Contains(err.Error(), store.path) || !strings.Contains(err.Error(), "owner-only") {
		t.Fatalf("load error = %v, want named owner-only ACL rejection", err)
	}
}

func TestCredentialStore_WindowsRejectsReparsePointState(t *testing.T) {
	current := testAPIKey(103)
	store := newCredentialStoreAt(t.TempDir(), testEndpointOrigin, keyPrefix(current))
	if err := os.MkdirAll(filepath.Dir(store.path), 0o700); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(t.TempDir(), "state.json")
	data, err := json.Marshal(testCredentialState(current, ""))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, data, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, store.path); err != nil {
		if err == syscall.ERROR_PRIVILEGE_NOT_HELD {
			t.Skip("creating a Windows symlink requires developer mode or SeCreateSymbolicLinkPrivilege")
		}
		t.Fatal(err)
	}

	_, err = store.load(current)
	if err == nil || !strings.Contains(err.Error(), store.path) {
		t.Fatalf("load error = %v, want named reparse-point rejection", err)
	}
}

func grantWindowsCredentialReadToEveryone(t *testing.T, path string, directory bool) {
	t.Helper()
	file, err := openWindowsCredentialObject(path, directory, credentialReadControl|credentialWriteDACL)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	sid, err := currentWindowsUserSID()
	if err != nil {
		t.Fatal(err)
	}
	sddl := "D:P" +
		"(A;;FA;;;SY)" +
		"(A;;FA;;;BA)" +
		"(A;;FA;;;" + sid + ")" +
		"(A;;FR;;;WD)"
	if err := setWindowsCredentialACL(syscall.Handle(file.Fd()), sddl); err != nil {
		t.Fatal(err)
	}
}
