package infraops

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"fmt"
	"net"
	"net/url"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

const databaseUsage = `usage: ./run ops database [options] [-- psql-args...]

Options:
  --project PROJECT   GCP project
  --host NAME         Portal VM used for private routing
  --port PORT         local PostgreSQL port; defaults from 15432
  --user EMAIL        Cloud SQL IAM user matching ADC
  --psql              open psql instead of Postico 2
  --proxy-only        keep the tunnel open without starting a client
`

var emailAddress = regexp.MustCompile(`^[^@\s]+@[^@\s]+\.[^@\s]+$`)

type databaseOptions struct {
	project   string
	host      string
	port      int
	user      string
	psql      bool
	proxyOnly bool
	psqlArgs  []string
}

func parseDatabaseOptions(args []string) (databaseOptions, error) {
	options := databaseOptions{
		project: os.Getenv("EMISAR_GCP_PROJECT"),
		user:    os.Getenv("EMISAR_DATABASE_USER"),
	}
	for len(args) > 0 {
		switch args[0] {
		case "--project", "--host", "--port", "--user":
			if len(args) < 2 {
				return options, usage("%s requires a value", args[0])
			}
			value := args[1]
			switch args[0] {
			case "--project":
				options.project = value
			case "--host":
				options.host = value
			case "--user":
				options.user = value
			case "--port":
				port, err := strconv.Atoi(value)
				if err != nil {
					return options, usage("port must be numeric")
				}
				options.port = port
			}
			args = args[2:]
		case "--psql":
			options.psql, args = true, args[1:]
		case "--proxy-only":
			options.proxyOnly, args = true, args[1:]
		case "-h", "--help":
			return options, usage(databaseUsage)
		case "--":
			options.psqlArgs = append([]string(nil), args[1:]...)
			args = nil
		default:
			return options, usage("unknown option: %s", args[0])
		}
	}
	if options.host != "" && !hostName.MatchString(options.host) {
		return options, usage("invalid Portal host name: %s", options.host)
	}
	if options.port != 0 && (options.port < 1024 || options.port > 65534) {
		return options, usage("port must be between 1024 and 65534")
	}
	if options.user != "" && !emailAddress.MatchString(options.user) {
		return options, usage("user must be a Google account email address")
	}
	if options.proxyOnly && options.psql {
		return options, usage("--proxy-only cannot be combined with --psql")
	}
	if !options.psql && len(options.psqlArgs) != 0 {
		return options, usage("psql arguments after -- require --psql")
	}
	return options, nil
}

func portAvailable(port int) bool {
	listener, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
	if err != nil {
		return false
	}
	_ = listener.Close()
	return true
}

func freePort(start int) (int, error) {
	for port := start; port <= 65535; port++ {
		if portAvailable(port) {
			return port, nil
		}
	}
	return 0, fmt.Errorf("no free local port is available")
}

func waitForPort(ctx context.Context, label string, port int, done <-chan error) error {
	address := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	timer := time.NewTimer(10 * time.Second)
	defer timer.Stop()
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	for {
		connection, err := net.DialTimeout("tcp", address, 100*time.Millisecond)
		if err == nil {
			_ = connection.Close()
			return nil
		}
		select {
		case err := <-done:
			return fmt.Errorf("%s stopped before listening on %s: %w", label, address, err)
		case <-timer.C:
			return fmt.Errorf("timed out waiting for %s on %s", label, address)
		case <-ticker.C:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

func uuid5(value string) string {
	namespace, _ := hex.DecodeString("6ba7b8109dad11d180b400c04fd430c8")
	hash := sha1.New()
	_, _ = hash.Write(namespace)
	_, _ = hash.Write([]byte(value))
	bytes := hash.Sum(nil)
	bytes[6] = bytes[6]&0x0f | 0x50
	bytes[8] = bytes[8]&0x3f | 0x80
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x",
		bytes[0:4], bytes[4:6], bytes[6:8], bytes[8:10], bytes[10:16])
}

func posticoURL(connectionName, user string, port int) string {
	connectionID := connectionName + "/emisar/" + user
	target := url.URL{
		Scheme: "postico",
		User:   url.User(user),
		Host:   net.JoinHostPort("127.0.0.1", strconv.Itoa(port)),
		Path:   "/emisar",
		RawQuery: url.Values{
			"uuid":     {uuid5(connectionID)},
			"nickname": {"Emisar Production"},
		}.Encode(),
	}
	return target.String()
}

func (a *App) databaseInventory(ctx context.Context, project string) ([]instance, error) {
	output, err := a.output(ctx, a.Root, nil, "gcloud", "compute", "instances", "list",
		"--project="+project, "--filter=labels.cluster_name=emisar AND status=RUNNING",
		"--sort-by=name", "--format=value(name,zone.basename())")
	if err != nil {
		return nil, err
	}
	return parseInstances(output)
}

func chooseDatabaseHost(instances []instance, requested string) (instance, error) {
	if len(instances) == 0 {
		return instance{}, fmt.Errorf("no running Emisar Portal VM is available for private routing")
	}
	if requested == "" {
		return instances[0], nil
	}
	var matched []instance
	for _, candidate := range instances {
		if candidate.name == requested {
			matched = append(matched, candidate)
		}
	}
	if len(matched) == 0 {
		return instance{}, fmt.Errorf("running Portal host not found: %s", requested)
	}
	if len(matched) > 1 {
		return instance{}, fmt.Errorf("Portal host name is ambiguous across zones: %s", requested)
	}
	return matched[0], nil
}

type background struct {
	command *exec.Cmd
	done    chan error
	once    sync.Once
}

func startBackground(command *exec.Cmd) (*background, error) {
	if err := command.Start(); err != nil {
		return nil, err
	}
	process := &background{command: command, done: make(chan error, 1)}
	go func() { process.done <- command.Wait() }()
	return process, nil
}

func (process *background) stop() {
	process.once.Do(func() {
		if process.command.Process != nil {
			_ = process.command.Process.Kill()
		}
	})
}

func (a *App) database(ctx context.Context, args []string) error {
	if len(args) == 1 && (args[0] == "-h" || args[0] == "--help") {
		fmt.Fprint(a.Out, databaseUsage)
		return nil
	}
	options, err := parseDatabaseOptions(args)
	if err != nil {
		return err
	}
	required := []string{"gcloud", "cloud-sql-proxy"}
	if options.psql {
		required = append(required, "psql")
	} else if !options.proxyOnly {
		required = append(required, "open")
	}
	if err := a.require(required...); err != nil {
		return err
	}
	options.project, err = a.project(ctx, options.project)
	if err != nil {
		return err
	}
	if options.user == "" {
		output, err := a.output(ctx, a.Root, nil, "gcloud", "auth", "list",
			"--filter=status:ACTIVE", "--format=value(account)")
		if err != nil {
			return err
		}
		accounts := lines(output)
		if len(accounts) == 0 {
			return fmt.Errorf("no active gcloud account; run gcloud auth login")
		}
		options.user = accounts[0]
	}
	if !emailAddress.MatchString(options.user) {
		return fmt.Errorf("active gcloud account is not a user email; pass --user explicitly")
	}
	if _, err := a.output(ctx, a.Root, nil, "gcloud", "auth", "application-default", "print-access-token"); err != nil {
		return fmt.Errorf("Application Default Credentials are unavailable; run gcloud auth application-default login as %s", options.user)
	}
	users, err := a.output(ctx, a.Root, nil, "gcloud", "sql", "users", "list",
		"--project="+options.project, "--instance=emisar", "--filter=type=CLOUD_IAM_USER",
		"--format=value(name)")
	if err != nil {
		return err
	}
	provisioned := false
	for _, user := range lines(users) {
		if user == options.user {
			provisioned = true
		}
	}
	if !provisioned {
		return fmt.Errorf("%s is not provisioned as the Emisar Cloud SQL IAM operator", options.user)
	}
	instances, err := a.databaseInventory(ctx, options.project)
	if err != nil {
		return err
	}
	portal, err := chooseDatabaseHost(instances, options.host)
	if err != nil {
		return err
	}
	connection, err := a.output(ctx, a.Root, nil, "gcloud", "sql", "instances", "describe", "emisar",
		"--project="+options.project, "--format=value(connectionName)")
	if err != nil {
		return err
	}
	connectionName := strings.TrimSpace(string(connection))
	if connectionName == "" {
		return fmt.Errorf("Cloud SQL instance emisar was not found in project %s", options.project)
	}
	if options.port == 0 {
		options.port, err = freePort(15432)
		if err != nil {
			return err
		}
	} else if !portAvailable(options.port) {
		return fmt.Errorf("local port %d is already in use", options.port)
	}
	socksPort, err := freePort(options.port + 1)
	if err != nil {
		return fmt.Errorf("finding SOCKS port: %w", err)
	}

	fmt.Fprintf(a.Err, "Opening private route through %s (%s)...\n", portal.name, portal.zone)
	ssh := a.command(ctx, a.Root, nil, "gcloud", "compute", "ssh", portal.name,
		"--project="+options.project, "--zone="+portal.zone, "--tunnel-through-iap",
		"--", "-N", "-D", fmt.Sprintf("127.0.0.1:%d", socksPort), "-o", "ExitOnForwardFailure=yes")
	ssh.Stdin = nil
	sshProcess, err := startBackground(ssh)
	if err != nil {
		return fmt.Errorf("starting IAP SOCKS tunnel: %w", err)
	}
	defer sshProcess.stop()
	if err := waitForPort(ctx, "IAP SOCKS tunnel", socksPort, sshProcess.done); err != nil {
		return err
	}

	fmt.Fprintf(a.Err, "Starting Cloud SQL Auth Proxy on 127.0.0.1:%d...\n", options.port)
	proxy := a.command(ctx, a.Root, map[string]string{
		"ALL_PROXY": fmt.Sprintf("socks5://127.0.0.1:%d", socksPort),
	}, "cloud-sql-proxy", "--private-ip", "--auto-iam-authn", "--run-connection-test",
		"--address=127.0.0.1", fmt.Sprintf("--port=%d", options.port), connectionName)
	proxy.Stdin = nil
	proxyProcess, err := startBackground(proxy)
	if err != nil {
		return fmt.Errorf("starting Cloud SQL Auth Proxy: %w", err)
	}
	defer proxyProcess.stop()
	if err := waitForPort(ctx, "Cloud SQL Auth Proxy", options.port, proxyProcess.done); err != nil {
		return err
	}

	details := fmt.Sprintf(`
Host:     127.0.0.1
Port:     %d
Database: emisar
User:     %s
Password: none (automatic IAM authentication)
`, options.port, options.user)
	if options.proxyOnly {
		fmt.Fprintln(a.Out, "Database tunnel ready. Press Ctrl-C to stop it.")
		fmt.Fprint(a.Out, details)
		return waitForTunnel(ctx, sshProcess, proxyProcess)
	}
	if options.psql {
		fmt.Fprintf(a.Err, "Connecting to emisar as %s with psql...\n", options.user)
		psqlArgs := append([]string(nil), options.psqlArgs...)
		psqlArgs = append(psqlArgs,
			"--host=127.0.0.1", fmt.Sprintf("--port=%d", options.port),
			"--dbname=emisar", "--username="+options.user, "--no-password")
		return a.run(ctx, a.Root, map[string]string{
			"PGAPPNAME": "emisar-database-helper", "PGCONNECT_TIMEOUT": "15",
			"PGPASSWORD": "", "PGSSLMODE": "disable",
		}, "psql", psqlArgs...)
	}

	fmt.Fprintf(a.Err, "Opening Emisar Production in Postico 2 as %s...\n", options.user)
	if err := a.run(ctx, a.Root, nil, "open", "-a", "Postico 2",
		posticoURL(connectionName, options.user, options.port)); err != nil {
		return fmt.Errorf("Postico 2 could not be opened; use --psql: %w", err)
	}
	fmt.Fprintln(a.Out, "Postico 2 opened. Keep this terminal open while using the database.")
	fmt.Fprintln(a.Out, "Press Ctrl-C to stop the private tunnel.")
	fmt.Fprint(a.Out, details)
	return waitForTunnel(ctx, sshProcess, proxyProcess)
}

func waitForTunnel(ctx context.Context, processes ...*background) error {
	cases := make(chan error, len(processes))
	for _, process := range processes {
		go func(process *background) { cases <- <-process.done }(process)
	}
	select {
	case err := <-cases:
		if err == nil {
			return fmt.Errorf("database tunnel stopped unexpectedly")
		}
		return fmt.Errorf("database tunnel stopped unexpectedly: %w", err)
	case <-ctx.Done():
		return nil
	}
}
