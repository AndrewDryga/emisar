package devtool

import (
	"context"
	"crypto/sha256"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

func portFromURL(raw string) (int, error) {
	parsed, err := url.Parse(raw)
	if err != nil {
		return 0, err
	}
	port, err := strconv.Atoi(parsed.Port())
	if err != nil || port < 1 || port > 65535 {
		return 0, fmt.Errorf("URL has invalid port: %s", raw)
	}
	return port, nil
}

func (a *App) serveLock(port int, publicURL string) (*os.File, error) {
	dir, err := a.serveRuntimeDir()
	if err != nil {
		return nil, err
	}
	lock, err := os.OpenFile(filepath.Join(dir, fmt.Sprintf("serve-%d.lock", port)), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := lockFile(lock, true); err != nil {
		data, _ := io.ReadAll(lock)
		lock.Close()
		return nil, fmt.Errorf("another ./run serve already owns Phoenix at %s (%s)", publicURL, string(data))
	}
	if err := lock.Truncate(0); err != nil {
		lock.Close()
		return nil, err
	}
	_, _ = lock.Seek(0, 0)
	_, _ = fmt.Fprintf(lock, "pid %d", os.Getpid())
	return lock, nil
}

func portListening(port int) bool {
	connection, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), 200*time.Millisecond)
	if err != nil {
		return false
	}
	connection.Close()
	return true
}

func proxy(ctx context.Context, listenAddress, targetAddress string) (func(), error) {
	listener, err := net.Listen("tcp", listenAddress)
	if err != nil {
		return nil, err
	}
	proxyContext, cancel := context.WithCancel(ctx)
	go func() {
		<-proxyContext.Done()
		listener.Close()
	}()
	go func() {
		for {
			incoming, acceptErr := listener.Accept()
			if acceptErr != nil {
				return
			}
			go forwardConnection(incoming, targetAddress)
		}
	}()
	return func() { cancel(); listener.Close() }, nil
}

func forwardConnection(incoming net.Conn, targetAddress string) {
	defer incoming.Close()
	outgoing, err := net.Dial("tcp", targetAddress)
	if err != nil {
		return
	}
	defer outgoing.Close()
	done := make(chan struct{}, 2)
	copyHalf := func(destination, source net.Conn) {
		_, _ = io.Copy(destination, source)
		if tcp, ok := destination.(*net.TCPConn); ok {
			_ = tcp.CloseWrite()
		}
		done <- struct{}{}
	}
	go copyHalf(outgoing, incoming)
	go copyHalf(incoming, outgoing)
	<-done
}

type serviceForward struct {
	listenPort int
	target     string
}

func parseServiceForwards(value string) ([]serviceForward, error) {
	if strings.TrimSpace(value) == "" {
		return nil, nil
	}
	var forwards []serviceForward
	for _, entry := range strings.Split(value, ",") {
		parts := strings.Split(entry, ":")
		if len(parts) != 3 {
			return nil, fmt.Errorf("invalid COOP_FORWARD entry %q", entry)
		}
		listenPort, listenErr := strconv.Atoi(parts[0])
		targetPort, targetErr := strconv.Atoi(parts[2])
		if listenErr != nil || targetErr != nil || listenPort < 1 || listenPort > 65535 || targetPort < 1 || targetPort > 65535 || parts[1] == "" {
			return nil, fmt.Errorf("invalid COOP_FORWARD entry %q", entry)
		}
		forwards = append(forwards, serviceForward{
			listenPort: listenPort,
			target:     net.JoinHostPort(parts[1], strconv.Itoa(targetPort)),
		})
	}
	return forwards, nil
}

// Coop normally owns these loopback forwards. A repository command restores a
// missing listener from Coop's declared contract so the box retains the same
// localhost OIDC issuer as the host instead of inventing a second code path.
func (a *App) ensureBoxServiceForwards(ctx context.Context) error {
	if !a.inBox() {
		return nil
	}
	forwards, err := parseServiceForwards(os.Getenv("COOP_FORWARD"))
	if err != nil {
		return err
	}
	for _, forward := range forwards {
		if portListening(forward.listenPort) {
			continue
		}
		listenAddress := net.JoinHostPort("127.0.0.1", strconv.Itoa(forward.listenPort))
		stop, proxyErr := proxy(ctx, listenAddress, forward.target)
		if proxyErr != nil {
			if portListening(forward.listenPort) {
				continue
			}
			return fmt.Errorf("restoring Coop service forward %s to %s: %w", listenAddress, forward.target, proxyErr)
		}
		a.serviceForwardStops = append(a.serviceForwardStops, stop)
	}
	return nil
}

func (a *App) stopServiceForwards() {
	for _, stop := range a.serviceForwardStops {
		stop()
	}
	a.serviceForwardStops = nil
}

// serveRuntimeDir is where the lock, the pid, and a detached server's log live —
// one directory per workspace, so two checkouts never fight over either.
func (a *App) serveRuntimeDir() (string, error) {
	runtimeRoot := os.Getenv("XDG_RUNTIME_DIR")
	if runtimeRoot == "" {
		runtimeRoot = os.TempDir()
	}
	canonical, err := filepath.EvalSymlinks(a.Root)
	if err != nil {
		canonical = a.Root
	}
	key := sha256.Sum256([]byte(canonical))
	dir := filepath.Join(runtimeRoot, fmt.Sprintf("emisar-dev-%d", os.Getuid()), fmt.Sprintf("%x", key[:8]))
	return dir, os.MkdirAll(dir, 0o700)
}

func (a *App) serveLogPath() (string, error) {
	dir, err := a.serveRuntimeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "serve.log"), nil
}

// A detached server is a re-exec of this same command in its own session, so it
// survives the shell — or the agent turn — that asked for it. The CHILD takes
// the flock, which keeps `already owns Phoenix` working unchanged.
func (a *App) serveDetached(ctx context.Context) error {
	workspace, _, err := a.up(ctx)
	if err != nil {
		return err
	}
	port, err := portFromURL(workspace.PortalURL)
	if err != nil {
		return err
	}
	if portListening(port) {
		fmt.Fprintf(a.Out, "already serving at %s\n", workspace.PortalURL)
		return nil
	}
	logPath, err := a.serveLogPath()
	if err != nil {
		return err
	}
	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	defer logFile.Close()
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	command := exec.Command(executable, "serve")
	command.Dir = a.Root
	command.Env = os.Environ()
	command.Stdin, command.Stdout, command.Stderr = nil, logFile, logFile
	configureDetachedProcess(command)
	if err := command.Start(); err != nil {
		return err
	}
	if err := command.Process.Release(); err != nil {
		return err
	}
	if err := waitForPortState(ctx, port, true, 3*time.Minute); err != nil {
		return fmt.Errorf("%w — see %s", err, logPath)
	}
	fmt.Fprintf(a.Out, "serving at %s (detached, log: %s)\n", workspace.PortalURL, logPath)
	return nil
}

// Waits for the port to reach `want` — listening for a start, quiet for a stop.
func waitForPortState(ctx context.Context, port int, want bool, limit time.Duration) error {
	deadline := time.Now().Add(limit)
	for time.Now().Before(deadline) {
		if portListening(port) == want {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(200 * time.Millisecond):
		}
	}
	return fmt.Errorf("port %d did not become listening=%t within %s", port, want, limit)
}

// Stops whatever holds the port, detached or not: the pid in the lock file owns
// a whole process group, so the group signal reaches Phoenix itself.
func (a *App) serveStop(ctx context.Context) error {
	workspace, _, err := a.up(ctx)
	if err != nil {
		return err
	}
	port, err := portFromURL(workspace.PortalURL)
	if err != nil {
		return err
	}
	if !portListening(port) {
		fmt.Fprintf(a.Out, "nothing serving at %s\n", workspace.PortalURL)
		return nil
	}
	pid, err := a.servePID(port)
	if err != nil {
		return err
	}
	// `./run serve` traps SIGTERM and tears Phoenix down with it, so signal the
	// OWNER by pid. Signalling a process group instead only works when the owner
	// happens to lead one, which a foreground or nohup'd server does not — and
	// the failure is silent, which is how a stop that stopped nothing reported
	// success.
	if err := stopProcessID(pid); err != nil {
		return fmt.Errorf("signalling ./run serve (pid %d): %w", pid, err)
	}
	if err := waitForPortState(ctx, port, false, 20*time.Second); err != nil {
		return fmt.Errorf("%s is still held by pid %d after SIGTERM", workspace.PortalURL, pid)
	}
	fmt.Fprintf(a.Out, "stopped %s\n", workspace.PortalURL)
	return nil
}

func (a *App) serveStatus(ctx context.Context) error {
	workspace, _, err := a.up(ctx)
	if err != nil {
		return err
	}
	port, err := portFromURL(workspace.PortalURL)
	if err != nil {
		return err
	}
	logPath, err := a.serveLogPath()
	if err != nil {
		return err
	}
	if !portListening(port) {
		fmt.Fprintf(a.Out, "not serving — start it with ./run serve --detach (log: %s)\n", logPath)
		return nil
	}
	if pid, err := a.servePID(port); err == nil {
		fmt.Fprintf(a.Out, "serving at %s (pid %d, log: %s)\n", workspace.PortalURL, pid, logPath)
		return nil
	}
	fmt.Fprintf(a.Out, "serving at %s (log: %s)\n", workspace.PortalURL, logPath)
	return nil
}

// The owner writes `pid <n>` into the lock file it holds; an untracked process
// on the port leaves nothing to read, which is worth saying out loud.
func (a *App) servePID(port int) (int, error) {
	dir, err := a.serveRuntimeDir()
	if err != nil {
		return 0, err
	}
	data, err := os.ReadFile(filepath.Join(dir, fmt.Sprintf("serve-%d.lock", port)))
	if err != nil {
		return 0, fmt.Errorf("port %d is held by an untracked process: %w", port, err)
	}
	pid := 0
	if _, err := fmt.Sscanf(strings.TrimSpace(string(data)), "pid %d", &pid); err != nil || pid <= 0 {
		return 0, fmt.Errorf("port %d is held by an untracked process", port)
	}
	return pid, nil
}

func serveInvocation(interactive bool) (string, []string) {
	if interactive {
		return "iex", []string{"-S", "mix", "phx.server"}
	}
	return "mix", []string{"phx.server"}
}

func (a *App) serve(ctx context.Context, interactive bool) error {
	workspace, env, err := a.up(ctx)
	if err != nil {
		return err
	}
	listenPort, metricsPort, listenIP := 0, 0, "127.0.0.1"
	portalPublicPort, err := portFromURL(workspace.PortalURL)
	if err != nil {
		return err
	}
	metricsPublicPort, err := portFromURL(workspace.MetricsURL)
	if err != nil {
		return err
	}
	if a.inBox() {
		listenPort, metricsPort, listenIP = 4000, 9091, "0.0.0.0"
	} else {
		listenPort, metricsPort = portalPublicPort, metricsPublicPort
	}

	lock, err := a.serveLock(listenPort, workspace.PortalURL)
	if err != nil {
		return err
	}
	defer func() {
		_ = unlockFile(lock)
		_ = lock.Close()
	}()
	if portListening(listenPort) {
		return fmt.Errorf("cannot serve at %s: port %d is already held by an untracked process", workspace.PortalURL, listenPort)
	}
	if portListening(metricsPort) {
		return fmt.Errorf("cannot serve metrics: port %d is already held by an untracked process", metricsPort)
	}
	if err := a.waitForDependencies(ctx, workspace); err != nil {
		return err
	}
	if err := a.configureKeycloak(ctx, workspace); err != nil {
		return err
	}
	if err := a.prepareDatabase(ctx, env); err != nil {
		return err
	}

	stops := []func(){}
	defer func() {
		for _, stop := range stops {
			stop()
		}
	}()
	if a.inBox() {
		for _, pair := range [][2]int{{portalPublicPort, listenPort}, {metricsPublicPort, metricsPort}} {
			stop, proxyErr := proxy(ctx,
				net.JoinHostPort("127.0.0.1", strconv.Itoa(pair[0])),
				net.JoinHostPort("127.0.0.1", strconv.Itoa(pair[1])),
			)
			if proxyErr != nil {
				return fmt.Errorf("proxying port %d: %w", pair[0], proxyErr)
			}
			stops = append(stops, stop)
		}
	}

	fmt.Fprintf(a.Out, "serving Phoenix at %s\n", workspace.PortalURL)
	name, arguments := serveInvocation(interactive)
	command := exec.Command(name, arguments...)
	command.Dir = a.Portal
	command.Env = mergedEnv(env)
	command.Env = append(command.Env,
		"METRICS_PORT="+strconv.Itoa(metricsPort),
		"EMISAR_LISTEN_PORT="+strconv.Itoa(listenPort),
		"EMISAR_LISTEN_IP="+listenIP,
	)
	command.Stdin, command.Stdout, command.Stderr = a.In, a.Out, a.Err
	configureProcessGroup(command)
	if err := command.Start(); err != nil {
		return err
	}
	done := make(chan error, 1)
	go func() { done <- command.Wait() }()
	select {
	case err := <-done:
		return err
	case <-ctx.Done():
		_ = stopProcessGroup(command, false)
		select {
		case <-done:
			return nil
		case <-time.After(5 * time.Second):
			_ = stopProcessGroup(command, true)
			<-done
			return nil
		}
	}
}
