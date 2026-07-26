package browser

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/chromedp/cdproto/browser"
	"github.com/chromedp/chromedp"
)

type State struct {
	DaemonPID  int    `json:"pid"`
	BrowserPID int    `json:"browserPid"`
	WSEndpoint string `json:"wsEndpoint"`
	TLSSPKI    string `json:"tlsSpki"`
}

type Config struct {
	State   string
	Profile string
	Marker  string
	Log     string
	SPKI    string
	InBox   bool
	Out     io.Writer
	Err     io.Writer
}

type Manager struct{ Config }

func New(config Config) *Manager {
	if config.Out == nil {
		config.Out = os.Stdout
	}
	if config.Err == nil {
		config.Err = os.Stderr
	}
	return &Manager{Config: config}
}

func ResolveChrome() (string, error) {
	if explicit := os.Getenv("CHROME"); explicit != "" {
		return executable(explicit)
	}
	candidates := []string{
		"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
		"/usr/bin/chromium-headless-shell",
		"/usr/bin/chromium",
		"/usr/bin/google-chrome",
	}
	for _, candidate := range candidates {
		if path, err := executable(candidate); err == nil {
			return path, nil
		}
	}
	return "", fmt.Errorf("no Chrome/Chromium found; set CHROME or install Google Chrome/Chromium")
}

func executable(path string) (string, error) {
	info, err := os.Stat(path)
	if err != nil {
		return "", err
	}
	if info.IsDir() || info.Mode()&0o111 == 0 {
		return "", fmt.Errorf("%s is not executable", path)
	}
	return path, nil
}

func readState(path string) (State, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return State{}, err
	}
	var state State
	if err := json.Unmarshal(data, &state); err != nil {
		return State{}, err
	}
	if state.WSEndpoint == "" {
		return State{}, fmt.Errorf("browser state has no WebSocket endpoint")
	}
	return state, nil
}

func writeState(path string, state State) error {
	data, err := json.Marshal(state)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	if err := os.Chmod(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".browser-state-*")
	if err != nil {
		return err
	}
	defer os.Remove(temporary.Name())
	if err := temporary.Chmod(0o600); err != nil {
		return err
	}
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporary.Name(), path)
}

func endpointAlive(endpoint string) bool {
	if !strings.HasPrefix(endpoint, "ws://127.0.0.1:") {
		return false
	}
	endpoint = strings.TrimPrefix(endpoint, "ws://")
	endpoint = strings.TrimPrefix(endpoint, "wss://")
	host := strings.SplitN(endpoint, "/", 2)[0]
	client := &http.Client{Timeout: time.Second}
	response, err := client.Get("http://" + host + "/json/version")
	if err != nil {
		return false
	}
	response.Body.Close()
	return response.StatusCode/100 == 2
}

func (m *Manager) State() (State, error) {
	state, err := readState(m.Config.State)
	if err != nil {
		return State{}, err
	}
	if state.TLSSPKI != m.SPKI || !endpointAlive(state.WSEndpoint) {
		return State{}, fmt.Errorf("browser state is stale")
	}
	return state, nil
}

func (m *Manager) recover() (State, error) {
	marker, err := os.ReadFile(m.Marker)
	if err != nil || strings.TrimSpace(string(marker)) != m.SPKI {
		return State{}, fmt.Errorf("browser TLS marker does not match")
	}
	active, err := os.ReadFile(filepath.Join(m.Profile, "DevToolsActivePort"))
	if err != nil {
		return State{}, err
	}
	lines := strings.Split(strings.TrimSpace(string(active)), "\n")
	if len(lines) < 2 {
		return State{}, fmt.Errorf("invalid DevToolsActivePort")
	}
	if _, err := strconv.Atoi(lines[0]); err != nil {
		return State{}, err
	}
	state := State{WSEndpoint: "ws://127.0.0.1:" + lines[0] + lines[1], TLSSPKI: m.SPKI}
	if !endpointAlive(state.WSEndpoint) {
		return State{}, fmt.Errorf("recovered browser endpoint is unavailable")
	}
	if err := writeState(m.Config.State, state); err != nil {
		return State{}, err
	}
	return state, nil
}

func (m *Manager) Start(ctx context.Context, binary string) (State, error) {
	if err := os.MkdirAll(filepath.Dir(m.Config.State), 0o700); err != nil {
		return State{}, err
	}
	lock, err := os.OpenFile(m.Config.State+".lock", os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return State{}, err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return State{}, err
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)

	if state, err := m.State(); err == nil {
		return state, nil
	}
	_ = os.Remove(m.Config.State)
	if state, err := m.recover(); err == nil {
		return state, nil
	}
	if _, err := ResolveChrome(); err != nil {
		return State{}, err
	}
	if err := os.MkdirAll(m.Profile, 0o700); err != nil {
		return State{}, err
	}
	if err := os.Chmod(m.Profile, 0o700); err != nil {
		return State{}, err
	}
	logFile, err := os.OpenFile(m.Log, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return State{}, err
	}
	if err := logFile.Chmod(0o600); err != nil {
		logFile.Close()
		return State{}, err
	}
	command := exec.Command(binary, "__browser-daemon",
		"--state", m.Config.State,
		"--profile", m.Profile,
		"--marker", m.Marker,
		"--spki", m.SPKI,
	)
	if m.InBox {
		command.Args = append(command.Args, "--box")
	}
	command.Stdin = nil
	command.Stdout, command.Stderr = logFile, logFile
	command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := command.Start(); err != nil {
		logFile.Close()
		return State{}, err
	}
	logFile.Close()
	for range 100 {
		if state, err := m.State(); err == nil {
			return state, nil
		}
		select {
		case <-ctx.Done():
			return State{}, ctx.Err()
		case <-time.After(100 * time.Millisecond):
		}
	}
	return State{}, fmt.Errorf("browser did not start; see %s", m.Log)
}

func (m *Manager) Stop(ctx context.Context) error {
	state, err := readState(m.Config.State)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	allocator, cancelAllocator := chromedp.NewRemoteAllocator(ctx, state.WSEndpoint)
	defer cancelAllocator()
	browserContext, cancelBrowser := chromedp.NewContext(allocator)
	defer cancelBrowser()
	if err := chromedp.Run(browserContext, chromedp.ActionFunc(func(actionContext context.Context) error {
		return browser.Close().Do(actionContext)
	})); err != nil && endpointAlive(state.WSEndpoint) {
		return err
	}
	for range 50 {
		if !endpointAlive(state.WSEndpoint) {
			_ = os.Remove(m.Config.State)
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	return fmt.Errorf("browser did not stop")
}

func RunDaemon(ctx context.Context, config Config) error {
	if decoded, err := base64.StdEncoding.DecodeString(config.SPKI); err != nil || len(decoded) != 32 {
		return fmt.Errorf("TLS SPKI must be one base64-encoded SHA-256 hash")
	}
	chrome, err := ResolveChrome()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(config.Profile, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(config.Profile, 0o700); err != nil {
		return err
	}
	args := chromeArgs(config)
	active := filepath.Join(config.Profile, "DevToolsActivePort")
	if err := os.Remove(active); err != nil && !os.IsNotExist(err) {
		return err
	}
	command := exec.CommandContext(ctx, chrome, args...)
	command.Stdout, command.Stderr = config.Out, config.Err
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	// Chromium forks several children. Killing only the process created by Go
	// leaves those descendants alive in a box, so cancellation owns the group.
	command.Cancel = func() error {
		if err := syscall.Kill(-command.Process.Pid, syscall.SIGKILL); err != nil && err != syscall.ESRCH {
			return err
		}
		return nil
	}
	if err := command.Start(); err != nil {
		return err
	}
	var endpoint string
	for range 100 {
		data, readErr := os.ReadFile(active)
		if readErr == nil {
			lines := strings.Split(strings.TrimSpace(string(data)), "\n")
			if len(lines) >= 2 {
				endpoint = "ws://127.0.0.1:" + lines[0] + lines[1]
				break
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	if endpoint == "" {
		_ = command.Process.Kill()
		return fmt.Errorf("browser did not publish DevToolsActivePort")
	}
	if err := os.WriteFile(config.Marker, []byte(config.SPKI+"\n"), 0o600); err != nil {
		_ = command.Process.Kill()
		return err
	}
	if err := os.Chmod(config.Marker, 0o600); err != nil {
		_ = command.Process.Kill()
		return err
	}
	state := State{DaemonPID: os.Getpid(), BrowserPID: command.Process.Pid, WSEndpoint: endpoint, TLSSPKI: config.SPKI}
	if err := writeState(config.State, state); err != nil {
		_ = command.Process.Kill()
		return err
	}
	err = command.Wait()
	if current, readErr := readState(config.State); readErr == nil && current.DaemonPID == os.Getpid() {
		_ = os.Remove(config.State)
	}
	if ctx.Err() != nil {
		return nil
	}
	return err
}

func chromeArgs(config Config) []string {
	args := []string{
		"--headless=new",
		"--remote-debugging-address=127.0.0.1",
		"--remote-debugging-port=0",
		"--user-data-dir=" + config.Profile,
		"--force-prefers-reduced-motion",
		"--no-first-run",
		"--no-default-browser-check",
		"--ignore-certificate-errors-spki-list=" + config.SPKI,
	}
	if config.InBox {
		args = append(args, "--no-sandbox", "--disable-dev-shm-usage", "--disable-gpu")
	}
	return args
}
