package browser

import (
	"context"
	"fmt"
	"io"
	"os"
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

type Manager struct {
	Config
}

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
	return "", fmt.Errorf("repository browser automation is not supported on Windows")
}

func (m *Manager) State() (State, error) {
	return State{}, fmt.Errorf("repository browser automation is not supported on Windows")
}

func (m *Manager) Start(context.Context, string) (State, error) {
	return State{}, fmt.Errorf("repository browser automation is not supported on Windows")
}

func (m *Manager) Stop(context.Context) error {
	return fmt.Errorf("repository browser automation is not supported on Windows")
}

func RunDaemon(context.Context, Config) error {
	return fmt.Errorf("repository browser automation is not supported on Windows")
}
