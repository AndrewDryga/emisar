package main

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

const (
	credentialStateVersion  = 2
	maxCredentialStateBytes = 4 << 10
	apiKeyPrefixLength      = 12
	apiKeyRandomBytes       = 32

	rotationPrefixHeader = "X-Emisar-Rotation-Prefix"
	rotationHashHeader   = "X-Emisar-Rotation-Hash"
	rotationAckHeader    = "X-Emisar-Rotation-Ack"
)

type credentialState struct {
	Version         int    `json:"version"`
	EndpointOrigin  string `json:"endpoint_origin"`
	BootstrapPrefix string `json:"bootstrap_prefix"`
	Current         string `json:"current"`
	Pending         string `json:"pending,omitempty"`
}

type credentialFileOps struct {
	mkdirAll  func(string, os.FileMode) error
	chmod     func(string, os.FileMode) error
	readFile  func(string) ([]byte, error)
	createTmp func(string, string) (*os.File, error)
	write     func(*os.File, []byte) (int, error)
	syncFile  func(*os.File) error
	closeFile func(*os.File) error
	rename    func(string, string) error
	remove    func(string) error
	syncDir   func(string) error
}

type credentialStore struct {
	path            string
	legacyPath      string
	endpointOrigin  string
	bootstrapPrefix string
	random          io.Reader
	ops             credentialFileOps
}

func (store *credentialStore) withLock(fun func() error) error {
	dir := filepath.Dir(store.path)
	if err := store.secureDirectory(dir); err != nil {
		return err
	}
	unlock, err := lockCredentialFile(store.path + ".lock")
	if err != nil {
		return fmt.Errorf("lock credential state: %w", err)
	}
	defer unlock()
	return fun()
}

func defaultCredentialFileOps() credentialFileOps {
	return credentialFileOps{
		mkdirAll:  os.MkdirAll,
		chmod:     os.Chmod,
		readFile:  os.ReadFile,
		createTmp: os.CreateTemp,
		write:     func(file *os.File, data []byte) (int, error) { return file.Write(data) },
		syncFile:  func(file *os.File) error { return file.Sync() },
		closeFile: func(file *os.File) error { return file.Close() },
		rename:    os.Rename,
		remove:    os.Remove,
		syncDir:   syncCredentialDirectory,
	}
}

func newCredentialStore(endpointOrigin, bootstrapPrefix string) (*credentialStore, error) {
	configDir, err := os.UserConfigDir()
	if err != nil {
		return nil, err
	}
	return newCredentialStoreAt(configDir, endpointOrigin, bootstrapPrefix), nil
}

func newCredentialStoreAt(configDir, endpointOrigin, bootstrapPrefix string) *credentialStore {
	digest := sha256.Sum256([]byte(endpointOrigin + "\x00" + bootstrapPrefix))
	legacyDigest := sha256.Sum256([]byte(bootstrapPrefix))
	filename := hex.EncodeToString(digest[:]) + ".json"
	legacyFilename := hex.EncodeToString(legacyDigest[:]) + ".json"
	dir := filepath.Join(configDir, "emisar", "credentials")
	return &credentialStore{
		path:            filepath.Join(dir, filename),
		legacyPath:      filepath.Join(dir, legacyFilename),
		endpointOrigin:  endpointOrigin,
		bootstrapPrefix: bootstrapPrefix,
		random:          rand.Reader,
		ops:             defaultCredentialFileOps(),
	}
}

func (store *credentialStore) load(fallback string) (credentialState, error) {
	if err := store.validateExistingPath(); err != nil {
		return credentialState{}, err
	}
	data, err := store.ops.readFile(store.path)
	if errors.Is(err, os.ErrNotExist) {
		if _, legacyErr := os.Lstat(store.legacyPath); legacyErr == nil {
			return credentialState{}, errors.New(
				"unbound v1 credential state exists; set EMISAR_API_KEY to that file's current key, then remove the v1 file before retrying",
			)
		} else if !errors.Is(legacyErr, os.ErrNotExist) {
			return credentialState{}, fmt.Errorf("inspect unbound v1 credential state: %w", legacyErr)
		}
		state := credentialState{
			Version:         credentialStateVersion,
			EndpointOrigin:  store.endpointOrigin,
			BootstrapPrefix: store.bootstrapPrefix,
			Current:         fallback,
		}
		return state, state.validate(store.endpointOrigin, store.bootstrapPrefix)
	}
	if err != nil {
		return credentialState{}, fmt.Errorf("read credential state: %w", err)
	}

	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var state credentialState
	if err := decoder.Decode(&state); err != nil {
		return credentialState{}, fmt.Errorf("decode credential state: %w", err)
	}
	if err := ensureJSONEOF(decoder); err != nil {
		return credentialState{}, fmt.Errorf("decode credential state: %w", err)
	}
	if err := state.validate(store.endpointOrigin, store.bootstrapPrefix); err != nil {
		return credentialState{}, err
	}
	return state, nil
}

func (store *credentialStore) persist(state credentialState) error {
	if err := state.validate(store.endpointOrigin, store.bootstrapPrefix); err != nil {
		return err
	}
	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return fmt.Errorf("encode credential state: %w", err)
	}
	data = append(data, '\n')

	dir := filepath.Dir(store.path)
	if err := store.secureDirectory(dir); err != nil {
		return err
	}

	tmp, err := store.ops.createTmp(dir, ".credential-*.tmp")
	if err != nil {
		return fmt.Errorf("create credential temp file: %w", err)
	}
	tmpPath := tmp.Name()
	closed := false
	defer func() {
		if !closed {
			_ = tmp.Close()
		}
		_ = store.ops.remove(tmpPath)
	}()

	if err := tmp.Chmod(0o600); err != nil {
		return fmt.Errorf("secure credential temp file: %w", err)
	}
	if n, err := store.ops.write(tmp, data); err != nil {
		return fmt.Errorf("write credential state: %w", err)
	} else if n != len(data) {
		return fmt.Errorf("write credential state: %w", io.ErrShortWrite)
	}
	if err := store.ops.syncFile(tmp); err != nil {
		return fmt.Errorf("sync credential state: %w", err)
	}
	if err := store.ops.closeFile(tmp); err != nil {
		return fmt.Errorf("close credential state: %w", err)
	}
	closed = true
	if err := store.ops.rename(tmpPath, store.path); err != nil {
		return fmt.Errorf("replace credential state: %w", err)
	}
	if err := store.ops.syncDir(dir); err != nil {
		return fmt.Errorf("sync credential directory: %w", err)
	}
	return nil
}

func (store *credentialStore) secureDirectory(dir string) error {
	if err := store.ops.mkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("create credential directory: %w", err)
	}
	if err := rejectUnsafeCredentialDirectory(dir); err != nil {
		return fmt.Errorf("secure credential directory: %w", err)
	}
	if err := store.ops.chmod(dir, 0o700); err != nil {
		return fmt.Errorf("secure credential directory: %w", err)
	}
	return nil
}

func (store *credentialStore) validateExistingPath() error {
	info, err := os.Lstat(store.path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("inspect credential state: %w", err)
	}
	if !info.Mode().IsRegular() {
		return errors.New("credential state is not a regular file")
	}
	if info.Size() > maxCredentialStateBytes {
		return fmt.Errorf("credential state is %d bytes, limit is %d", info.Size(), maxCredentialStateBytes)
	}
	if runtime.GOOS == "windows" {
		return nil
	}
	if info.Mode().Perm()&0o077 != 0 {
		return fmt.Errorf("credential state permissions are %04o, want owner-only", info.Mode().Perm())
	}
	if err := rejectUnsafeCredentialDirectory(filepath.Dir(store.path)); err != nil {
		return fmt.Errorf("credential directory is unsafe: %w", err)
	}
	dirInfo, err := os.Lstat(filepath.Dir(store.path))
	if err != nil {
		return fmt.Errorf("inspect credential directory: %w", err)
	}
	if dirInfo.Mode().Perm()&0o077 != 0 {
		return fmt.Errorf("credential directory permissions are %04o, want owner-only", dirInfo.Mode().Perm())
	}
	return nil
}

func rejectUnsafeCredentialDirectory(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return errors.New("symbolic links are not allowed")
	}
	if !info.IsDir() {
		return errors.New("path is not a directory")
	}
	return nil
}

func (state credentialState) validate(endpointOrigin, bootstrapPrefix string) error {
	switch {
	case state.Version != credentialStateVersion:
		return fmt.Errorf("unsupported credential state version %d", state.Version)
	case state.EndpointOrigin != endpointOrigin:
		return errors.New("credential state endpoint origin does not match")
	case state.BootstrapPrefix != bootstrapPrefix:
		return errors.New("credential state bootstrap prefix does not match")
	case !validAPIKey(state.Current):
		return errors.New("credential state has an invalid current key")
	case state.Pending != "" && !validAPIKey(state.Pending):
		return errors.New("credential state has an invalid pending key")
	case state.Pending != "" && state.Pending == state.Current:
		return errors.New("credential state pending key matches current key")
	default:
		return nil
	}
}

func syncCredentialDirectory(dir string) error {
	if runtime.GOOS == "windows" {
		return nil
	}
	directory, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}

func generateAPIKey(random io.Reader) (string, error) {
	secret := make([]byte, apiKeyRandomBytes)
	if _, err := io.ReadFull(random, secret); err != nil {
		return "", fmt.Errorf("generate API key: %w", err)
	}
	return "emk-" + base64.RawURLEncoding.EncodeToString(secret), nil
}

func validAPIKey(key string) bool {
	if !strings.HasPrefix(key, "emk-") {
		return false
	}
	secret, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(key, "emk-"))
	return err == nil && len(secret) == apiKeyRandomBytes
}

func newRotationStore(endpointOrigin, apiKey string) (*credentialStore, error) {
	if !validAPIKey(apiKey) {
		return nil, nil
	}
	return newCredentialStore(endpointOrigin, keyPrefix(apiKey))
}

func keyPrefix(key string) string {
	if len(key) < apiKeyPrefixLength {
		return key
	}
	return key[:apiKeyPrefixLength]
}

func rotationHash(key string) string {
	digest := sha256.Sum256([]byte(key))
	return hex.EncodeToString(digest[:])
}

// refreshCredentialState adopts a peer process's durable transition before the
// next HTTP request. Re-persisting changed state proves the observed rename and
// its parent-directory entry durable before a proposal depends on its pending
// secret or first use can retire the predecessor on the portal.
func (b *bridge) refreshCredentialState() error {
	if b.credentialStore == nil {
		return nil
	}

	b.stateMu.Lock()
	defer b.stateMu.Unlock()
	return b.credentialStore.withLock(func() error {
		state, err := b.credentialStore.load(b.apiKey)
		if err != nil {
			return err
		}
		if state.Current != b.apiKey || state.Pending != b.pendingKey {
			if err := b.credentialStore.persist(state); err != nil {
				return fmt.Errorf("confirm peer credential state: %w", err)
			}
		}
		b.apiKey = state.Current
		b.pendingKey = state.Pending
		return nil
	})
}

func (b *bridge) rotationProposal(method string) (prefix, hash string) {
	if method != "initialize" || b.credentialStore == nil {
		return "", ""
	}

	b.stateMu.Lock()
	defer b.stateMu.Unlock()
	activatedDurably := false
	err := b.credentialStore.withLock(func() error {
		state, err := b.credentialStore.load(b.apiKey)
		if err != nil {
			return err
		}
		currentChanged := state.Current != b.apiKey
		if currentChanged || state.Pending != b.pendingKey {
			// A peer may have completed the rename before its directory sync
			// failed. Re-sync any observed transition before this process relies
			// on the pending secret or lets first use retire the old credential.
			if err := b.credentialStore.persist(state); err != nil {
				return err
			}
		}
		b.apiKey = state.Current
		b.pendingKey = state.Pending
		if currentChanged && state.Pending == "" {
			activatedDurably = true
			return nil
		}
		if b.pendingKey != "" {
			return nil
		}

		pending, err := generateAPIKey(b.credentialStore.random)
		if err != nil {
			return err
		}
		state.Pending = pending
		if err := b.credentialStore.persist(state); err != nil {
			return err
		}
		b.pendingKey = pending
		return nil
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "emisar-mcp: API-key rotation preparation was not persisted: %v\n", err)
		return "", ""
	}
	if activatedDurably {
		return "", ""
	}
	return keyPrefix(b.pendingKey), rotationHash(b.pendingKey)
}

func (b *bridge) acknowledgeRotation(ack string) {
	b.stateMu.Lock()
	defer b.stateMu.Unlock()
	if b.credentialStore == nil || b.pendingKey == "" || len(ack) != sha256.Size*2 {
		return
	}
	expected := rotationHash(b.pendingKey)
	if subtle.ConstantTimeCompare([]byte(strings.ToLower(ack)), []byte(expected)) != 1 {
		return
	}

	pending := b.pendingKey
	err := b.credentialStore.withLock(func() error {
		state, err := b.credentialStore.load(b.apiKey)
		if err != nil {
			return err
		}
		if state.Current == pending && state.Pending == "" {
			// Another process may have completed the rename after this request
			// began. Re-persist to prove the promoted state durable locally
			// before this process starts using the successor.
			return b.credentialStore.persist(state)
		}
		if state.Pending != pending {
			return errors.New("credential state pending key changed before acknowledgement")
		}
		state.Current = pending
		state.Pending = ""
		return b.credentialStore.persist(state)
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "emisar-mcp: API-key rotation acknowledgement was not persisted: %v\n", err)
		return
	}
	b.apiKey = pending
	b.pendingKey = ""
	fmt.Fprintf(os.Stderr, "emisar-mcp: rotated API key persisted to %s\n", b.credentialStore.path)
}
