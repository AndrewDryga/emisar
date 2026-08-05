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
	"syscall"
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
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	lock, err := os.OpenFile(filepath.Join(dir, fmt.Sprintf("serve-%d.lock", port)), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
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
		_ = syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
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
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := command.Start(); err != nil {
		return err
	}
	done := make(chan error, 1)
	go func() { done <- command.Wait() }()
	select {
	case err := <-done:
		return err
	case <-ctx.Done():
		_ = syscall.Kill(-command.Process.Pid, syscall.SIGTERM)
		select {
		case <-done:
			return nil
		case <-time.After(5 * time.Second):
			_ = syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
			<-done
			return nil
		}
	}
}
