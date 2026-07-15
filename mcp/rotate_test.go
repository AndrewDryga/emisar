package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"sync"
	"testing"
	"testing/iotest"
)

const testEndpointOrigin = "https://example.test"

func TestGenerateAPIKey_UsesPortalCompatibleShapeAndStrongRandomness(t *testing.T) {
	random := bytes.NewReader(bytes.Repeat([]byte{0x5a}, apiKeyRandomBytes))
	key, err := generateAPIKey(random)
	if err != nil {
		t.Fatalf("generateAPIKey: %v", err)
	}
	if !validAPIKey(key) {
		t.Fatalf("generated key has invalid shape: %q", key)
	}
	if got := keyPrefix(key); got != key[:apiKeyPrefixLength] || len(got) != 12 {
		t.Fatalf("key prefix = %q, want portal's 12-byte lookup prefix", got)
	}

	if _, err := generateAPIKey(iotest.ErrReader(errors.New("entropy unavailable"))); err == nil {
		t.Fatal("random-source failure must prevent generation")
	}
}

func TestCredentialStore_PersistsAndLoadsOwnerOnlyState(t *testing.T) {
	current := testAPIKey(1)
	pending := testAPIKey(2)
	store := newCredentialStoreAt(t.TempDir(), testEndpointOrigin, keyPrefix(current))
	state := testCredentialState(current, pending)

	if err := store.persist(state); err != nil {
		t.Fatalf("persist: %v", err)
	}
	loaded, err := store.load("unused fallback")
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if loaded != state {
		t.Fatalf("loaded state = %#v, want %#v", loaded, state)
	}

	if runtime.GOOS != "windows" {
		fileInfo, err := os.Stat(store.path)
		if err != nil {
			t.Fatalf("stat state: %v", err)
		}
		if fileInfo.Mode().Perm() != 0o600 {
			t.Errorf("state mode = %o, want 600", fileInfo.Mode().Perm())
		}
		dirInfo, err := os.Stat(filepath.Dir(store.path))
		if err != nil {
			t.Fatalf("stat state dir: %v", err)
		}
		if dirInfo.Mode().Perm() != 0o700 {
			t.Errorf("state dir mode = %o, want 700", dirInfo.Mode().Perm())
		}
	}
}

func TestCredentialStore_NamespacesStateByCanonicalEndpointOrigin(t *testing.T) {
	configDir := t.TempDir()
	current := testAPIKey(24)
	state := testCredentialState(current, testAPIKey(25))
	storeA := newCredentialStoreAt(configDir, "https://a.example", keyPrefix(current))
	storeB := newCredentialStoreAt(configDir, "https://b.example", keyPrefix(current))
	if storeA.path == storeB.path {
		t.Fatal("different endpoint origins share a credential-state path")
	}
	state.EndpointOrigin = storeA.endpointOrigin
	if err := storeA.persist(state); err != nil {
		t.Fatalf("persist endpoint A: %v", err)
	}

	data, err := os.ReadFile(storeA.path)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(storeB.path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := storeB.load(current); err == nil {
		t.Fatal("credential state copied from another endpoint origin was accepted")
	}
}

func TestCredentialStore_RejectsUnboundV1State(t *testing.T) {
	current := testAPIKey(26)
	store := newCredentialStoreAt(t.TempDir(), testEndpointOrigin, keyPrefix(current))
	if err := os.MkdirAll(filepath.Dir(store.path), 0o700); err != nil {
		t.Fatal(err)
	}
	legacy := `{"version":1,"bootstrap_prefix":"` + keyPrefix(current) +
		`","current":"` + current + `"}`
	if err := os.WriteFile(store.legacyPath, []byte(legacy), 0o600); err != nil {
		t.Fatal(err)
	}

	if _, err := store.load(current); err == nil || !strings.Contains(err.Error(), "unbound v1") {
		t.Fatalf("unbound legacy state error = %v", err)
	}
	if _, err := os.Stat(store.path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("legacy refusal created endpoint-bound state: %v", err)
	}
}

func TestNewRotationStore_BypassesNonRotatableBearers(t *testing.T) {
	for _, bearer := range []string{
		"emo-oauth-access-token",
		"arbitrary-bearer",
		"emk-malformed",
	} {
		store, err := newRotationStore(testEndpointOrigin, bearer)
		if err != nil || store != nil {
			t.Fatalf("newRotationStore(%q) = %#v, %v; want nil, nil", bearer, store, err)
		}
	}
}

func TestCredentialStore_RejectsCorruptStateWithoutOverwritingIt(t *testing.T) {
	current := testAPIKey(3)
	store := newCredentialStoreAt(t.TempDir(), testEndpointOrigin, keyPrefix(current))
	if err := os.MkdirAll(filepath.Dir(store.path), 0o700); err != nil {
		t.Fatal(err)
	}
	corrupt := []byte(`{"version":1,"current":"secret"}`)
	if err := os.WriteFile(store.path, corrupt, 0o600); err != nil {
		t.Fatal(err)
	}

	if _, err := store.load(current); err == nil {
		t.Fatal("corrupt credential state must fail closed")
	}
	got, err := os.ReadFile(store.path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, corrupt) {
		t.Fatalf("corrupt state was overwritten: %q", got)
	}
}

func TestCredentialStore_RejectsUnknownFieldsAndWrongBootstrap(t *testing.T) {
	current := testAPIKey(4)
	store := newCredentialStoreAt(t.TempDir(), testEndpointOrigin, keyPrefix(current))
	if err := os.MkdirAll(filepath.Dir(store.path), 0o700); err != nil {
		t.Fatal(err)
	}

	unknown := `{"version":1,"bootstrap_prefix":"` + keyPrefix(current) +
		`","current":"` + current + `","extra":true}`
	if err := os.WriteFile(store.path, []byte(unknown), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := store.load(current); err == nil {
		t.Fatal("unknown fields must fail closed")
	}

	wrong := testCredentialState(current, "")
	wrong.BootstrapPrefix = "emk-wrong123"
	data, _ := json.Marshal(wrong)
	if err := os.WriteFile(store.path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := store.load(current); err == nil {
		t.Fatal("a state file for another bootstrap must fail closed")
	}
}

func TestCredentialStore_RejectsUnsafePaths(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Unix mode and symlink checks do not apply on Windows")
	}

	t.Run("broad file permissions", func(t *testing.T) {
		current := testAPIKey(19)
		store := newCredentialStoreAt(t.TempDir(), testEndpointOrigin, keyPrefix(current))
		if err := store.persist(testCredentialState(current, "")); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(store.path, 0o644); err != nil {
			t.Fatal(err)
		}
		if _, err := store.load(current); err == nil {
			t.Fatal("broadly readable credential state must fail closed")
		}
	})

	t.Run("broad directory permissions", func(t *testing.T) {
		current := testAPIKey(21)
		store := newCredentialStoreAt(t.TempDir(), testEndpointOrigin, keyPrefix(current))
		if err := store.persist(testCredentialState(current, "")); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(filepath.Dir(store.path), 0o755); err != nil {
			t.Fatal(err)
		}
		if _, err := store.load(current); err == nil {
			t.Fatal("credential state in a broadly accessible directory must fail closed")
		}
	})

	t.Run("symlinked state file", func(t *testing.T) {
		current := testAPIKey(20)
		store := newCredentialStoreAt(t.TempDir(), testEndpointOrigin, keyPrefix(current))
		if err := os.MkdirAll(filepath.Dir(store.path), 0o700); err != nil {
			t.Fatal(err)
		}
		target := filepath.Join(t.TempDir(), "state.json")
		data, _ := json.Marshal(testCredentialState(current, ""))
		if err := os.WriteFile(target, data, 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(target, store.path); err != nil {
			t.Fatal(err)
		}
		if _, err := store.load(current); err == nil {
			t.Fatal("symlinked credential state must fail closed")
		}
	})

	t.Run("oversized state file", func(t *testing.T) {
		current := testAPIKey(22)
		store := newCredentialStoreAt(t.TempDir(), testEndpointOrigin, keyPrefix(current))
		if err := os.MkdirAll(filepath.Dir(store.path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(store.path, bytes.Repeat([]byte{'x'}, maxCredentialStateBytes+1), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := store.load(current); err == nil {
			t.Fatal("oversized credential state must fail closed")
		}
	})
}

func TestCredentialStore_FailureBoundariesLeaveACompleteOldOrNewState(t *testing.T) {
	stages := []struct {
		name   string
		inject func(*credentialStore, error)
		isNew  bool
	}{
		{"directory create", func(store *credentialStore, injected error) {
			store.ops.mkdirAll = func(string, os.FileMode) error { return injected }
		}, false},
		{"directory chmod", func(store *credentialStore, injected error) {
			store.ops.chmod = func(string, os.FileMode) error { return injected }
		}, false},
		{"temp create", func(store *credentialStore, injected error) {
			store.ops.createTmp = func(string, string) (*os.File, error) { return nil, injected }
		}, false},
		{"write", func(store *credentialStore, injected error) {
			store.ops.write = func(*os.File, []byte) (int, error) { return 0, injected }
		}, false},
		{"short write", func(store *credentialStore, _ error) {
			store.ops.write = func(*os.File, []byte) (int, error) { return 1, nil }
		}, false},
		{"file sync", func(store *credentialStore, injected error) {
			store.ops.syncFile = func(*os.File) error { return injected }
		}, false},
		{"file close", func(store *credentialStore, injected error) {
			store.ops.closeFile = func(*os.File) error { return injected }
		}, false},
		{"rename", func(store *credentialStore, injected error) {
			store.ops.rename = func(string, string) error { return injected }
		}, false},
		{"directory sync", func(store *credentialStore, injected error) {
			store.ops.syncDir = func(string) error { return injected }
		}, true},
	}

	for _, stage := range stages {
		t.Run(stage.name, func(t *testing.T) {
			current := testAPIKey(5)
			pending := testAPIKey(6)
			store := newCredentialStoreAt(t.TempDir(), testEndpointOrigin, keyPrefix(current))
			oldState := testCredentialState(current, "")
			if err := store.persist(oldState); err != nil {
				t.Fatalf("seed old state: %v", err)
			}

			injected := errors.New("injected " + stage.name + " failure")
			stage.inject(store, injected)
			newState := testCredentialState(current, pending)
			if err := store.persist(newState); err == nil {
				t.Fatal("persist unexpectedly succeeded")
			}

			store.ops = defaultCredentialFileOps()
			loaded, err := store.load("unused")
			if err != nil {
				t.Fatalf("failure left corrupt state: %v", err)
			}
			want := oldState
			if stage.isNew {
				want = newState
			}
			if loaded != want {
				t.Fatalf("state after failure = %#v, want complete %#v", loaded, want)
			}
		})
	}
}

func TestForward_RotationPersistsPendingBeforeRequestAndCurrentBeforeActivation(t *testing.T) {
	current := testAPIKey(7)
	store := newCredentialStoreAt(t.TempDir(), testEndpointOrigin, keyPrefix(current))
	var proposalHash string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		proposalHash = r.Header.Get(rotationHashHeader)
		loaded, err := store.load("unused")
		if err != nil {
			t.Errorf("pending was not readable when request arrived: %v", err)
		}
		if loaded.Current != current || loaded.Pending == "" {
			t.Errorf("request arrived before durable pending state: %#v", loaded)
		}
		if r.Header.Get(rotationPrefixHeader) != keyPrefix(loaded.Pending) ||
			proposalHash != rotationHash(loaded.Pending) {
			t.Error("proposal headers do not match durable pending key")
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set(rotationAckHeader, proposalHash)
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18"}}`))
	}))
	defer srv.Close()

	b := newRotationTestBridge(store, current)
	b.endpoint = srv.URL
	if _, err := b.forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"initialize"}`)); err != nil {
		t.Fatalf("forward: %v", err)
	}
	if b.apiKey == current || b.pendingKey != "" {
		t.Fatalf("rotation was not activated after durable acknowledgement: current=%q pending=%q", b.apiKey, b.pendingKey)
	}
	loaded, err := store.load("unused")
	if err != nil {
		t.Fatalf("load promoted state: %v", err)
	}
	if loaded.Current != b.apiKey || loaded.Pending != "" {
		t.Fatalf("activated key is not the durable current key: %#v", loaded)
	}
}

func TestForward_LostRequestKeepsOldKeyAndRecoverablePending(t *testing.T) {
	current := testAPIKey(8)
	store := newCredentialStoreAt(t.TempDir(), testEndpointOrigin, keyPrefix(current))
	b := newRotationTestBridge(store, current)
	b.client = &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		return nil, errors.New("request lost")
	})}

	if _, err := b.forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"initialize"}`)); err == nil {
		t.Fatal("lost request must surface an error")
	}
	assertOldWithPending(t, b, store, current)
}

func TestForward_LostResponseRetriesSamePendingAndRecoversAfterRestart(t *testing.T) {
	current := testAPIKey(9)
	store := newCredentialStoreAt(t.TempDir(), testEndpointOrigin, keyPrefix(current))
	b := newRotationTestBridge(store, current)
	b.client = &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		return &http.Response{
			StatusCode: http.StatusOK,
			Header: http.Header{
				"Content-Type":    []string{"application/json"},
				rotationAckHeader: []string{req.Header.Get(rotationHashHeader)},
			},
			Body: io.NopCloser(iotest.ErrReader(errors.New("response lost"))),
		}, nil
	})}

	if _, err := b.forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"initialize"}`)); err == nil {
		t.Fatal("lost response must surface an error")
	}
	assertOldWithPending(t, b, store, current)
	pending := b.pendingKey

	restartedState, err := store.load(current)
	if err != nil {
		t.Fatalf("restart load: %v", err)
	}
	restarted := newRotationTestBridge(store, restartedState.Current)
	restarted.pendingKey = restartedState.Pending
	restarted.client = &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		if got := req.Header.Get(rotationHashHeader); got != rotationHash(pending) {
			t.Errorf("retry proposal hash = %q, want original pending hash", got)
		}
		return jsonRPCResponse(req.Header.Get(rotationHashHeader)), nil
	})}

	if _, err := restarted.forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"initialize"}`)); err != nil {
		t.Fatalf("retry after restart: %v", err)
	}
	if restarted.apiKey != pending || restarted.pendingKey != "" {
		t.Fatal("retry acknowledgement did not promote the recovered pending key")
	}
}

func TestAcknowledgeRotation_PersistFailureNeverActivatesPending(t *testing.T) {
	stages := []struct {
		name   string
		inject func(*credentialStore, error)
	}{
		{"rename", func(store *credentialStore, injected error) {
			store.ops.rename = func(string, string) error { return injected }
		}},
		{"directory sync", func(store *credentialStore, injected error) {
			store.ops.syncDir = func(string) error { return injected }
		}},
	}

	for _, stage := range stages {
		t.Run(stage.name, func(t *testing.T) {
			current := testAPIKey(10)
			store := newCredentialStoreAt(t.TempDir(), testEndpointOrigin, keyPrefix(current))
			b := newRotationTestBridge(store, current)
			_, hash := b.rotationProposal("initialize")
			pending := b.pendingKey
			stage.inject(store, errors.New("injected "+stage.name+" failure"))

			b.acknowledgeRotation(hash)
			if b.apiKey != current || b.pendingKey != pending {
				t.Fatal("failed acknowledgement persistence changed active rotation state")
			}

			store.ops = defaultCredentialFileOps()
			prefix, proposalHash := b.rotationProposal("initialize")
			if stage.name == "directory sync" {
				if b.apiKey != pending || b.pendingKey != "" {
					t.Fatal("complete promoted state was not re-synced before activation")
				}
				if prefix != "" || proposalHash != "" {
					t.Fatal("reconciliation unexpectedly prepared another rotation")
				}
			} else {
				if b.apiKey != current || b.pendingKey != pending {
					t.Fatal("pre-rename failure did not retain the old and pending keys")
				}
				if prefix != keyPrefix(pending) || proposalHash != rotationHash(pending) {
					t.Fatal("pre-rename failure did not retry the same pending proposal")
				}
			}
		})
	}
}

func TestRotationProposal_GenerationFailureAndNoConfigStayOnOldKey(t *testing.T) {
	current := testAPIKey(11)
	store := newCredentialStoreAt(t.TempDir(), testEndpointOrigin, keyPrefix(current))
	store.random = iotest.ErrReader(errors.New("entropy unavailable"))
	b := newRotationTestBridge(store, current)
	if prefix, hash := b.rotationProposal("initialize"); prefix != "" || hash != "" {
		t.Fatalf("generation failure produced proposal %q/%q", prefix, hash)
	}
	if _, err := os.Stat(store.path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("generation failure wrote state: %v", err)
	}
	if b.apiKey != current || b.pendingKey != "" {
		t.Fatal("generation failure changed rotation state")
	}

	withoutConfig := newRotationTestBridge(nil, current)
	if prefix, hash := withoutConfig.rotationProposal("initialize"); prefix != "" || hash != "" {
		t.Fatal("bridge without durable config must not offer a successor")
	}
}

func TestAcknowledgeRotation_WrongAckIsIgnored(t *testing.T) {
	current := testAPIKey(12)
	store := newCredentialStoreAt(t.TempDir(), testEndpointOrigin, keyPrefix(current))
	b := newRotationTestBridge(store, current)
	_, _ = b.rotationProposal("initialize")
	pending := b.pendingKey
	b.acknowledgeRotation(strings.Repeat("0", 64))
	if b.apiKey != current || b.pendingKey != pending {
		t.Fatal("mismatched acknowledgement changed rotation state")
	}
}

func TestCredentialStore_DifferentPrefixesPersistConcurrently(t *testing.T) {
	configDir := t.TempDir()
	currentA := testAPIKey(13)
	currentB := testAPIKey(14)
	storeA := newCredentialStoreAt(configDir, testEndpointOrigin, keyPrefix(currentA))
	storeB := newCredentialStoreAt(configDir, testEndpointOrigin, keyPrefix(currentB))
	if storeA.path == storeB.path {
		t.Fatal("different bootstrap prefixes share a credential file")
	}

	var wait sync.WaitGroup
	for _, pair := range []struct {
		store *credentialStore
		state credentialState
	}{{storeA, testCredentialState(currentA, testAPIKey(15))}, {storeB, testCredentialState(currentB, testAPIKey(16))}} {
		wait.Add(1)
		go func() {
			defer wait.Done()
			for range 50 {
				if err := pair.store.persist(pair.state); err != nil {
					t.Errorf("concurrent persist: %v", err)
					return
				}
			}
		}()
	}
	wait.Wait()

	for store, want := range map[*credentialStore]credentialState{
		storeA: testCredentialState(currentA, testAPIKey(15)),
		storeB: testCredentialState(currentB, testAPIKey(16)),
	} {
		got, err := store.load("unused")
		if err != nil || got != want {
			t.Fatalf("stored state = %#v, %v; want %#v", got, err, want)
		}
	}
}

func TestRotationProposal_SamePrefixProcessesConvergeOnOnePendingKey(t *testing.T) {
	configDir := t.TempDir()
	current := testAPIKey(18)
	storeA := newCredentialStoreAt(configDir, testEndpointOrigin, keyPrefix(current))
	storeB := newCredentialStoreAt(configDir, testEndpointOrigin, keyPrefix(current))
	storeA.random = bytes.NewReader(bytes.Repeat([]byte{0xa1}, apiKeyRandomBytes))
	storeB.random = bytes.NewReader(bytes.Repeat([]byte{0xb2}, apiKeyRandomBytes))
	bridgeA := newRotationTestBridge(storeA, current)
	bridgeB := newRotationTestBridge(storeB, current)

	type proposal struct{ prefix, hash string }
	proposals := make(chan proposal, 2)
	var wait sync.WaitGroup
	for _, candidate := range []*bridge{bridgeA, bridgeB} {
		wait.Add(1)
		go func() {
			defer wait.Done()
			prefix, hash := candidate.rotationProposal("initialize")
			proposals <- proposal{prefix, hash}
		}()
	}
	wait.Wait()
	close(proposals)

	var first proposal
	for candidate := range proposals {
		if candidate.prefix == "" || candidate.hash == "" {
			t.Fatalf("empty proposal: %#v", candidate)
		}
		if first == (proposal{}) {
			first = candidate
		} else if candidate != first {
			t.Fatalf("same-prefix processes proposed different keys: %#v vs %#v", first, candidate)
		}
	}
	if bridgeA.pendingKey != bridgeB.pendingKey || bridgeA.pendingKey == "" {
		t.Fatal("same-prefix processes did not load the same durable pending secret")
	}
}

func TestForward_PeerPromotionRefreshesLiveBridge(t *testing.T) {
	configDir := t.TempDir()
	current := testAPIKey(27)
	storeA := newCredentialStoreAt(configDir, testEndpointOrigin, keyPrefix(current))
	storeB := newCredentialStoreAt(configDir, testEndpointOrigin, keyPrefix(current))
	peer := newRotationTestBridge(storeA, current)
	live := newRotationTestBridge(storeB, current)

	_, acknowledgement := peer.rotationProposal("initialize")
	if err := live.refreshCredentialState(); err != nil {
		t.Fatalf("load pending peer state: %v", err)
	}
	peer.acknowledgeRotation(acknowledgement)

	var authorization string
	live.client = &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		authorization = req.Header.Get("Authorization")
		return jsonRPCResponse(""), nil
	})}
	if _, err := live.forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call"}`)); err != nil {
		t.Fatalf("forward after peer promotion: %v", err)
	}
	if want := "Bearer " + peer.apiKey; authorization != want {
		t.Fatalf("authorization = %q, want peer-promoted %q", authorization, want)
	}
	if live.apiKey != peer.apiKey || live.pendingKey != "" {
		t.Fatal("live bridge did not adopt the peer-promoted credential state")
	}
}

func TestInitializeCredentialState_ReadOnlyFallbackWaitsForAuthFailure(t *testing.T) {
	configDir := t.TempDir()
	current := testAPIKey(31)
	pending := testAPIKey(32)
	successor := testAPIKey(33)
	store := newCredentialStoreAt(configDir, testEndpointOrigin, keyPrefix(current))
	if err := store.persist(testCredentialState(current, pending)); err != nil {
		t.Fatal(err)
	}
	store.ops.chmod = func(string, os.FileMode) error { return os.ErrPermission }

	b := newRotationTestBridge(store, current)
	readOnly, err := b.initializeCredentialState()
	if err != nil {
		t.Fatalf("initialize read-only credential state: %v", err)
	}
	if !readOnly || !b.credentialReadOnly {
		t.Fatal("permission denial did not enable read-only credential state")
	}
	if b.apiKey != current || b.pendingKey != "" {
		t.Fatalf("read-only initial state = %q/%q, want configured current and no pending", b.apiKey, b.pendingKey)
	}
	if prefix, hash := b.rotationProposal("initialize"); prefix != "" || hash != "" {
		t.Fatalf("read-only bridge proposed a rotation: prefix=%q hash=%q", prefix, hash)
	}

	peerStore := newCredentialStoreAt(configDir, testEndpointOrigin, keyPrefix(current))
	promoted := testCredentialState(current, "")
	promoted.Current = successor
	if err := peerStore.persist(promoted); err != nil {
		t.Fatal(err)
	}
	if err := b.refreshCredentialState(); err != nil {
		t.Fatalf("refresh read-only state: %v", err)
	}
	if b.apiKey != current || b.pendingKey != "" {
		t.Fatalf("read-only bridge adopted an unproven peer successor: current=%q pending=%q", b.apiKey, b.pendingKey)
	}
	recovery, err := b.readOnlyRecoveryKey()
	if err != nil || recovery != successor {
		t.Fatalf("read-only recovery key = %q, err=%v, want peer successor", recovery, err)
	}
}

func TestForward_ReadOnlyCredentialRetriesSuccessorAfterUnauthorized(t *testing.T) {
	current := testAPIKey(38)
	successor := testAPIKey(39)
	store := newCredentialStoreAt(t.TempDir(), testEndpointOrigin, keyPrefix(current))
	state := testCredentialState(current, successor)
	if err := store.persist(state); err != nil {
		t.Fatal(err)
	}
	store.ops.chmod = func(string, os.FileMode) error { return os.ErrPermission }

	b := newRotationTestBridge(store, current)
	if readOnly, err := b.initializeCredentialState(); err != nil || !readOnly {
		t.Fatalf("initialize read-only state: readOnly=%t err=%v", readOnly, err)
	}
	var authorizations, idempotencyKeys []string
	b.client = &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		authorizations = append(authorizations, req.Header.Get("Authorization"))
		idempotencyKeys = append(idempotencyKeys, req.Header.Get("Idempotency-Key"))
		if req.Header.Get("Authorization") == "Bearer "+current {
			return &http.Response{
				StatusCode: http.StatusUnauthorized,
				Header:     http.Header{"Content-Type": []string{"application/json"}},
				Body: io.NopCloser(strings.NewReader(
					`{"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"unauthorized"}}`,
				)),
			}, nil
		}
		return jsonRPCResponse(""), nil
	})}

	if _, err := b.forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"ping"}`)); err != nil {
		t.Fatalf("forward with read-only recovery: %v", err)
	}
	wantAuth := []string{"Bearer " + current, "Bearer " + successor}
	if !slices.Equal(authorizations, wantAuth) {
		t.Fatalf("authorization attempts = %#v, want %#v", authorizations, wantAuth)
	}
	if len(idempotencyKeys) != 2 || idempotencyKeys[0] == "" || idempotencyKeys[0] != idempotencyKeys[1] {
		t.Fatalf("retry changed idempotency identity: %#v", idempotencyKeys)
	}
	if b.apiKey != successor || b.pendingKey != "" {
		t.Fatalf("successful recovery was not adopted: current=%q pending=%q", b.apiKey, b.pendingKey)
	}
}

func TestForward_ReadOnlyCredentialDoesNotRaceVisiblePeerPromotion(t *testing.T) {
	current := testAPIKey(40)
	successor := testAPIKey(41)
	store := newCredentialStoreAt(t.TempDir(), testEndpointOrigin, keyPrefix(current))
	promoted := testCredentialState(current, "")
	promoted.Current = successor
	if err := store.persist(promoted); err != nil {
		t.Fatal(err)
	}
	store.ops.chmod = func(string, os.FileMode) error { return os.ErrPermission }

	b := newRotationTestBridge(store, current)
	if readOnly, err := b.initializeCredentialState(); err != nil || !readOnly {
		t.Fatalf("initialize read-only state: readOnly=%t err=%v", readOnly, err)
	}
	var authorization string
	b.client = &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		authorization = req.Header.Get("Authorization")
		return jsonRPCResponse(""), nil
	})}

	if _, err := b.forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"ping"}`)); err != nil {
		t.Fatal(err)
	}
	if authorization != "Bearer "+current || b.apiKey != current {
		t.Fatalf("visible peer rename was activated before auth failure: authorization=%q current=%q", authorization, b.apiKey)
	}
}

func TestInitializeCredentialState_ReadOnlyFallbackStillRejectsCorruptState(t *testing.T) {
	current := testAPIKey(34)
	store := newCredentialStoreAt(t.TempDir(), testEndpointOrigin, keyPrefix(current))
	if err := os.MkdirAll(filepath.Dir(store.path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(store.path, []byte(`{"version":2,"current":"corrupt"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	store.ops.chmod = func(string, os.FileMode) error { return os.ErrPermission }

	b := newRotationTestBridge(store, current)
	if readOnly, err := b.initializeCredentialState(); err == nil || readOnly {
		t.Fatalf("corrupt state enabled read-only fallback: readOnly=%t err=%v", readOnly, err)
	}
}

func TestInitializeCredentialState_PostRenameFailureStaysFatal(t *testing.T) {
	current := testAPIKey(35)
	successor := testAPIKey(36)
	store := newCredentialStoreAt(t.TempDir(), testEndpointOrigin, keyPrefix(current))
	if err := store.persist(testCredentialState(current, "")); err != nil {
		t.Fatal(err)
	}

	promoted := testCredentialState(current, "")
	promoted.Current = successor
	store.ops.syncDir = func(string) error { return os.ErrPermission }
	if err := store.persist(promoted); err == nil {
		t.Fatal("simulated peer promotion unexpectedly synced")
	}

	b := newRotationTestBridge(store, current)
	readOnly, err := b.initializeCredentialState()
	if err == nil || readOnly || b.credentialReadOnly {
		t.Fatalf("post-rename failure enabled read-only activation: readOnly=%t err=%v", readOnly, err)
	}
	if b.apiKey != current || b.pendingKey != "" {
		t.Fatal("post-rename failure activated an unproven successor")
	}
}

func TestForward_ProposalDoesNotTransmitPendingSecret(t *testing.T) {
	current := testAPIKey(17)
	store := newCredentialStoreAt(t.TempDir(), testEndpointOrigin, keyPrefix(current))
	b := newRotationTestBridge(store, current)
	b.client = &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		loaded, err := store.load("unused")
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(req.Body)
		for name, values := range req.Header {
			if name != "Authorization" && strings.Contains(strings.Join(values, ","), loaded.Pending) {
				t.Errorf("pending secret leaked through header %s", name)
			}
		}
		if bytes.Contains(body, []byte(loaded.Pending)) {
			t.Error("pending secret leaked through JSON-RPC body")
		}
		return jsonRPCResponse(""), nil
	})}

	if _, err := b.forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"initialize"}`)); err != nil {
		t.Fatalf("forward: %v", err)
	}
}

func testAPIKey(fill byte) string {
	return "emk-" + base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{fill}, apiKeyRandomBytes))
}

func testCredentialState(current, pending string) credentialState {
	return credentialState{
		Version:         credentialStateVersion,
		EndpointOrigin:  testEndpointOrigin,
		BootstrapPrefix: keyPrefix(current),
		Current:         current,
		Pending:         pending,
	}
}

func newRotationTestBridge(store *credentialStore, current string) *bridge {
	return &bridge{
		endpoint:        "https://example.test/api/mcp/rpc",
		apiKey:          current,
		userAgent:       "emisar-mcp/test",
		client:          newHTTPClient(),
		sessionID:       "rotation-test",
		credentialStore: store,
	}
}

func assertOldWithPending(t *testing.T, b *bridge, store *credentialStore, current string) {
	t.Helper()
	if b.apiKey != current || b.pendingKey == "" {
		t.Fatalf("active/pending state = %q/%q, want old plus pending", b.apiKey, b.pendingKey)
	}
	loaded, err := store.load("unused")
	if err != nil {
		t.Fatalf("load pending state: %v", err)
	}
	if loaded.Current != current || loaded.Pending != b.pendingKey {
		t.Fatalf("durable state = %#v, want old plus pending", loaded)
	}
}

func jsonRPCResponse(ack string) *http.Response {
	header := http.Header{"Content-Type": []string{"application/json"}}
	if ack != "" {
		header.Set(rotationAckHeader, ack)
	}
	return &http.Response{
		StatusCode: http.StatusOK,
		Header:     header,
		Body: io.NopCloser(strings.NewReader(
			`{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18"}}`,
		)),
		Request: (&http.Request{}).WithContext(context.Background()),
	}
}
