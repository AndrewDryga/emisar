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
	"time"
)

const (
	credentialStateVersion  = 2
	maxCredentialStateBytes = 4 << 10
	cliAccountFilePrefix    = "account-"
	apiKeyPrefixLength      = 12
	apiKeyRandomBytes       = 32

	rotationPrefixHeader = "X-Emisar-Rotation-Prefix"
	rotationHashHeader   = "X-Emisar-Rotation-Hash"
	rotationAckHeader    = "X-Emisar-Rotation-Ack"
)

type credentialState struct {
	Version         int    `json:"version"`
	EndpointOrigin  string `json:"endpoint_origin"`
	AccountID       string `json:"account_id,omitempty"`
	AccountSlug     string `json:"account_slug,omitempty"`
	AccountName     string `json:"account_name,omitempty"`
	BootstrapPrefix string `json:"bootstrap_prefix"`
	Current         string `json:"current"`
	Pending         string `json:"pending,omitempty"`
}

// Every write-side op takes the *os.Root secureDirectory validated rather than
// a path. A path is re-resolved on each call, so the credential directory could
// be swapped for a symlink between the check and the create — on a shared host
// where the parent is group-writable, that redirects the pending key into a
// directory the attacker owns. A root is a pinned directory descriptor: once
// opened, replacing the directory entry cannot move where these writes land.
type credentialFileOps struct {
	mkdirAll  func(string, os.FileMode) error
	chmod     func(string, os.FileMode) error
	readFile  func(string) ([]byte, error)
	openRoot  func(string) (*os.Root, error)
	createTmp func(*os.Root, string) (*os.File, error)
	write     func(*os.File, []byte) (int, error)
	syncFile  func(*os.File) error
	closeFile func(*os.File) error
	rename    func(*os.Root, string, string) error
	remove    func(*os.Root, string) error
	syncDir   func(*os.Root) error
}

type credentialStore struct {
	path            string
	endpointOrigin  string
	bootstrapPrefix string
	random          io.Reader
	ops             credentialFileOps
}

// credentialWriteAccessError marks failures that occur before the credential
// state callback can mutate the state file. Only this phase is eligible for a
// read-only sandbox fallback; persistence failures may have crossed rename.
type credentialWriteAccessError struct {
	err error
}

func (err *credentialWriteAccessError) Error() string { return err.err.Error() }
func (err *credentialWriteAccessError) Unwrap() error { return err.err }

// credentialStateStamp fingerprints the on-disk state this process last proved
// durable (size + mtime of the atomically renamed file). A matching stamp lets
// the per-request refresh/proposal skip the flock + read cycle entirely; every
// peer transition renames a freshly written temp file into place, so it changes
// the stamp. The one theoretical miss — two same-size rewrites inside a single
// filesystem-timestamp quantum — self-heals through the 401 recovery path,
// which always re-reads under the lock.
type credentialStateStamp struct {
	valid   bool
	size    int64
	modTime time.Time
}

func (stamp credentialStateStamp) matches(current credentialStateStamp) bool {
	return stamp.valid && current.valid &&
		stamp.size == current.size && stamp.modTime.Equal(current.modTime)
}

func (store *credentialStore) stamp() credentialStateStamp {
	info, err := os.Lstat(store.path)
	if err != nil || !info.Mode().IsRegular() {
		return credentialStateStamp{}
	}
	return credentialStateStamp{valid: true, size: info.Size(), modTime: info.ModTime()}
}

func (store *credentialStore) withLock(fun func() error) error {
	root, err := store.secureDirectory(filepath.Dir(store.path))
	if err != nil {
		return &credentialWriteAccessError{err: err}
	}
	// This call wants only the directory preparation. persist opens its own
	// root for the writes that need one, so this descriptor closes here rather
	// than staying open for the whole locked section.
	_ = root.Close()
	unlock, err := lockCredentialFile(store.path + ".lock")
	if err != nil {
		return &credentialWriteAccessError{err: fmt.Errorf("lock credential state: %w", err)}
	}
	defer unlock()
	return fun()
}

func defaultCredentialFileOps() credentialFileOps {
	return credentialFileOps{
		mkdirAll: os.MkdirAll,
		chmod:    os.Chmod,
		readFile: os.ReadFile,
		openRoot: os.OpenRoot,
		createTmp: func(root *os.Root, name string) (*os.File, error) {
			// O_EXCL so a pre-planted name is a failure, never a reuse.
			return root.OpenFile(name, os.O_RDWR|os.O_CREATE|os.O_EXCL, 0o600)
		},
		write:     func(file *os.File, data []byte) (int, error) { return file.Write(data) },
		syncFile:  func(file *os.File) error { return file.Sync() },
		closeFile: func(file *os.File) error { return file.Close() },
		rename:    func(root *os.Root, from, to string) error { return root.Rename(from, to) },
		remove:    func(root *os.Root, name string) error { return root.Remove(name) },
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
	filename := hex.EncodeToString(digest[:]) + ".json"
	dir := filepath.Join(configDir, "emisar", "credentials")
	return &credentialStore{
		path:            filepath.Join(dir, filename),
		endpointOrigin:  endpointOrigin,
		bootstrapPrefix: bootstrapPrefix,
		random:          rand.Reader,
		ops:             defaultCredentialFileOps(),
	}
}

func newCLIAccountCredentialStore(accountID, endpointOrigin, bootstrapPrefix string) (*credentialStore, error) {
	configDir, err := os.UserConfigDir()
	if err != nil {
		return nil, err
	}
	return newCLIAccountCredentialStoreAt(configDir, accountID, endpointOrigin, bootstrapPrefix), nil
}

func newCLIAccountCredentialStoreAt(configDir, accountID, endpointOrigin, bootstrapPrefix string) *credentialStore {
	dir := filepath.Join(configDir, "emisar", "credentials")
	digest := sha256.Sum256([]byte(endpointOrigin + "\x00" + accountID))
	filename := cliAccountFilePrefix + hex.EncodeToString(digest[:]) + ".json"
	return &credentialStore{
		path:            filepath.Join(dir, filename),
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

	state, err := decodeCredentialState(data)
	if err != nil {
		return credentialState{}, err
	}
	if err := state.validate(store.endpointOrigin, store.bootstrapPrefix); err != nil {
		return credentialState{}, err
	}
	return state, nil
}

func decodeCredentialState(data []byte) (credentialState, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var state credentialState
	if err := decoder.Decode(&state); err != nil {
		return credentialState{}, fmt.Errorf("decode credential state: %w", err)
	}
	if err := ensureJSONEOF(decoder); err != nil {
		return credentialState{}, fmt.Errorf("decode credential state: %w", err)
	}
	return state, nil
}

func (store *credentialStore) persist(state credentialState) error {
	if err := state.validate(store.endpointOrigin, store.bootstrapPrefix); err != nil {
		return err
	}
	return store.persistJSON(state)
}

func (store *credentialStore) persistJSON(value any) error {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return fmt.Errorf("encode credential state: %w", err)
	}
	data = append(data, '\n')

	root, err := store.secureDirectory(filepath.Dir(store.path))
	if err != nil {
		return err
	}
	defer root.Close()

	tmpName := ".credential-" + rand.Text() + ".tmp"
	tmp, err := store.ops.createTmp(root, tmpName)
	if err != nil {
		return fmt.Errorf("create credential temp file: %w", err)
	}
	closed := false
	defer func() {
		if !closed {
			_ = tmp.Close()
		}
		_ = store.ops.remove(root, tmpName)
	}()

	if err := tmp.Chmod(0o600); err != nil {
		return fmt.Errorf("secure credential temp file: %w", err)
	}
	if err := validateCredentialTempFileAccess(tmp); err != nil {
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
	if err := store.ops.rename(root, tmpName, filepath.Base(store.path)); err != nil {
		return fmt.Errorf("replace credential state: %w", err)
	}
	if err := store.ops.syncDir(root); err != nil {
		return fmt.Errorf("sync credential directory: %w", err)
	}
	return nil
}

// secureDirectory returns the directory as a pinned descriptor. Every check it
// makes is by path and therefore expires the moment it returns; the root is
// what carries that decision forward to the writes in persist.
func (store *credentialStore) secureDirectory(dir string) (*os.Root, error) {
	if err := store.ops.mkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("create credential directory: %w", err)
	}
	if err := rejectUnsafeCredentialDirectory(dir); err != nil {
		return nil, fmt.Errorf("secure credential directory %s: %w", dir, err)
	}
	if err := store.ops.chmod(dir, 0o700); err != nil {
		return nil, fmt.Errorf("secure credential directory: %w", err)
	}
	securedDirectory, err := secureCredentialDirectoryAccess(dir)
	if err != nil {
		return nil, fmt.Errorf("secure credential directory %s: %w", dir, err)
	}
	defer securedDirectory.Close()
	root, err := store.ops.openRoot(dir)
	if err != nil {
		return nil, fmt.Errorf("open credential directory: %w", err)
	}
	securedInfo, securedErr := securedDirectory.Stat()
	rootInfo, rootErr := root.Stat(".")
	if securedErr != nil || rootErr != nil || !os.SameFile(securedInfo, rootInfo) {
		_ = root.Close()
		switch {
		case securedErr != nil:
			return nil, fmt.Errorf("inspect secured credential directory %s: %w", dir, securedErr)
		case rootErr != nil:
			return nil, fmt.Errorf("inspect opened credential directory %s: %w", dir, rootErr)
		default:
			return nil, fmt.Errorf("credential directory %s changed while it was being secured", dir)
		}
	}
	return root, nil
}

func (store *credentialStore) validateExistingPath() error {
	info, err := os.Lstat(store.path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("inspect credential state: %w", err)
	}
	// Every failure here names the offending path: the operator has to go fix a
	// file whose location they never chose, and the message is all they get.
	if !info.Mode().IsRegular() {
		return fmt.Errorf("credential state %s is not a regular file", store.path)
	}
	if info.Size() > maxCredentialStateBytes {
		return fmt.Errorf("credential state %s is %d bytes, limit is %d", store.path, info.Size(), maxCredentialStateBytes)
	}
	if err := validateCredentialFileAccess(store.path, info); err != nil {
		return fmt.Errorf("credential state %s is unsafe: %w", store.path, err)
	}
	dir := filepath.Dir(store.path)
	if err := rejectUnsafeCredentialDirectory(dir); err != nil {
		return fmt.Errorf("credential directory %s is unsafe: %w", dir, err)
	}
	dirInfo, err := os.Lstat(dir)
	if err != nil {
		return fmt.Errorf("inspect credential directory %s: %w", dir, err)
	}
	if err := validateCredentialDirectoryAccess(dir, dirInfo); err != nil {
		return fmt.Errorf("credential directory %s is unsafe: %w", dir, err)
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
	if state.AccountID != "" || state.AccountSlug != "" || state.AccountName != "" {
		if err := validateAccountIdentity(state.AccountID, state.AccountSlug, state.AccountName); err != nil {
			return fmt.Errorf("credential state: %w", err)
		}
	}
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

func syncCredentialDirectory(root *os.Root) error {
	if runtime.GOOS == "windows" {
		return nil
	}
	directory, err := root.Open(".")
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

// initializeCredentialState prefers the locked, durable rotation path. Some
// MCP clients sandbox their server processes away from the user's config
// directory. A write denial before the state callback runs may safely fall back
// to validated reads. Any persistence failure remains fatal because rename may
// already have happened without a durable directory sync.
func (b *bridge) initializeCredentialState() (bool, error) {
	err := b.refreshCredentialState()
	if err == nil || b.credentialStore == nil {
		return false, err
	}
	var accessErr *credentialWriteAccessError
	if !errors.As(err, &accessErr) || !isCredentialWriteUnavailable(accessErr) {
		return false, err
	}

	b.stateMu.Lock()
	b.credentialReadOnly = true
	b.pendingKey = ""
	b.stateMu.Unlock()
	if readErr := b.refreshCredentialState(); readErr != nil {
		return false, fmt.Errorf("writable state unavailable (%v); read-only state: %w", err, readErr)
	}
	return true, nil
}

// withSyncedStore wraps a locked credential-state transition and records the
// resulting on-disk stamp while still under the flock, so the per-request fast
// paths can skip disk while nothing changes. A failed transition invalidates
// the stamp, forcing the next request back through the full locked cycle.
// Callers hold b.stateMu.
func (b *bridge) withSyncedStore(fun func() error) error {
	return b.credentialStore.withLock(func() error {
		if err := fun(); err != nil {
			b.credentialStamp = credentialStateStamp{}
			return err
		}
		b.credentialStamp = b.credentialStore.stamp()
		return nil
	})
}

// refreshCredentialState adopts a peer process's durable transition before the
// next HTTP request. Re-persisting changed state proves the observed rename and
// its parent-directory entry durable before a proposal depends on its pending
// secret or first use can retire the predecessor on the portal. In the steady
// state — the file unchanged since this process last synced it — the stamp
// check answers without the flock or a read.
func (b *bridge) refreshCredentialState() error {
	if b.credentialStore == nil {
		return nil
	}

	b.stateMu.Lock()
	defer b.stateMu.Unlock()
	if b.credentialReadOnly {
		// Stamp captured before the read: racing a peer rename can only leave
		// an older stamp, so staleness costs a reload, never a missed change.
		stamp := b.credentialStore.stamp()
		if b.credentialStamp.matches(stamp) {
			return nil
		}
		_, err := b.credentialStore.load(b.apiKey)
		if err != nil {
			b.credentialStamp = credentialStateStamp{}
			return err
		}
		b.pendingKey = ""
		b.credentialStamp = stamp
		return nil
	}
	if b.credentialStamp.matches(b.credentialStore.stamp()) {
		return nil
	}
	return b.withSyncedStore(func() error {
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

// credentialRecoveryKey returns a durable alternate only after the portal has
// rejected the attempted key. A pending successor is not activated until the
// portal accepts it; a peer-promoted current key is re-synced before use.
func (b *bridge) credentialRecoveryKey(rejected string) (string, error) {
	b.stateMu.Lock()
	defer b.stateMu.Unlock()
	if b.credentialStore == nil {
		return "", nil
	}

	if b.credentialReadOnly {
		state, err := b.credentialStore.load(rejected)
		if err != nil {
			return "", err
		}
		if state.Current != rejected {
			return state.Current, nil
		}
		if state.Pending != "" && state.Pending != rejected {
			return state.Pending, nil
		}
		return "", nil
	}

	var alternate string
	err := b.withSyncedStore(func() error {
		state, err := b.credentialStore.load(rejected)
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
		switch {
		case state.Current != rejected:
			alternate = state.Current
		case state.Pending != "" && state.Pending != rejected:
			alternate = state.Pending
		}
		return nil
	})
	if err != nil {
		return "", err
	}
	return alternate, nil
}

// adoptRecoveryKey records an alternate only after the portal accepted it. A
// writable pending successor may retire its predecessor on first use, so the
// promotion must be durable before the successful response is released.
func (b *bridge) adoptRecoveryKey(key string) error {
	b.stateMu.Lock()
	defer b.stateMu.Unlock()
	if b.credentialStore == nil {
		return nil
	}
	if b.credentialReadOnly {
		b.apiKey = key
		b.pendingKey = ""
		return nil
	}

	err := b.withSyncedStore(func() error {
		state, err := b.credentialStore.load(b.apiKey)
		if err != nil {
			return err
		}
		switch {
		case state.Current == key && state.Pending == "":
			// Re-persist a peer promotion so this process has proved it durable.
		case state.Pending == key:
			state.Current = key
			state.Pending = ""
		default:
			return errors.New("credential recovery key changed before adoption")
		}
		return b.credentialStore.persist(state)
	})
	if err != nil {
		return err
	}
	b.apiKey = key
	b.pendingKey = ""
	return nil
}

func (b *bridge) rotationProposal() (prefix, hash string) {
	if b.credentialStore == nil {
		return "", ""
	}

	b.stateMu.Lock()
	defer b.stateMu.Unlock()
	if b.credentialReadOnly {
		return "", ""
	}
	// Steady state: this process already prepared a successor and the file has
	// not moved since it last synced — re-offer the same proposal without disk.
	if b.pendingKey != "" && b.credentialStamp.matches(b.credentialStore.stamp()) {
		return keyPrefix(b.pendingKey), rotationHash(b.pendingKey)
	}
	activatedDurably := false
	err := b.withSyncedStore(func() error {
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
		b.diagnose("API-key rotation preparation was not persisted: %v", err)
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
	if b.credentialStore == nil || b.credentialReadOnly || b.pendingKey == "" || len(ack) != sha256.Size*2 {
		return
	}
	expected := rotationHash(b.pendingKey)
	if subtle.ConstantTimeCompare([]byte(strings.ToLower(ack)), []byte(expected)) != 1 {
		return
	}

	pending := b.pendingKey
	err := b.withSyncedStore(func() error {
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
		b.diagnose("API-key rotation acknowledgement was not persisted: %v", err)
		return
	}
	b.apiKey = pending
	b.pendingKey = ""
	b.diagnose("rotated API key persisted to %s", b.credentialStore.path)
}
