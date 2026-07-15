package executor

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"hash"
	"io"
	"os"
	"os/exec"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Stream identifies which output stream a chunk came from.
type Stream string

const (
	StreamStdout Stream = "stdout"
	StreamStderr Stream = "stderr"
)

// Plan is the prepared, fully-rendered invocation. The action runtime
// constructs this from a validated action call; the executor never
// re-renders templates.
type Plan struct {
	Binary       string
	Argv         []string
	CWD          string
	Env          map[string]string
	Limits       Limits
	ScriptSHA256 string

	// User is the local OS username to drop to before exec. Empty =
	// inherit the runner's uid/gid. Resolved at start time on Linux
	// (os/user.Lookup → SysProcAttr.Credential). On non-Linux the field
	// is logged and ignored.
	User string

	// CancelGrace is the time between SIGTERM and SIGKILL when the context
	// is cancelled (cloud `cancel` or timeout). Defaults to 30s if zero.
	CancelGrace time.Duration

	// OnChunk, if non-nil, is called from background goroutines as soon as a
	// complete line of output arrives. When set, Result.Stdout/Stderr are
	// left empty — the caller takes ownership of the streamed bytes. Use
	// this to forward progress to the cloud over the websocket.
	OnChunk func(stream Stream, data []byte)
}

// DefaultCancelGrace is the default SIGTERM->SIGKILL window.
const DefaultCancelGrace = 30 * time.Second

// Executor runs prepared Plans.
type Executor struct {
	// InheritEnv lists environment variable names that are inherited from
	// the parent process when not explicitly set on the Plan.
	InheritEnv []string
}

// DefaultInheritEnv is the always-on allowlist of inherited env vars: the
// minimum any action needs — PATH (so binaries resolve) and locale. Operator
// config extends this via AllowInheritEnv; it never replaces it.
var DefaultInheritEnv = []string{"PATH", "LANG", "LC_ALL", "TERM"}

// New returns an Executor seeded with a copy of DefaultInheritEnv. The copy
// keeps callers (and AllowInheritEnv) from mutating the package-level slice.
func New() *Executor {
	return &Executor{InheritEnv: append([]string(nil), DefaultInheritEnv...)}
}

// AllowInheritEnv adds env var names to the inherit allowlist on top of what's
// already there (deduped, order preserved). Operator-configured inherit_env
// extends the defaults rather than replacing them, so adding a var like
// NOMAD_TOKEN can never silently drop PATH and break binary resolution.
func (e *Executor) AllowInheritEnv(keys ...string) {
	seen := make(map[string]struct{}, len(e.InheritEnv))
	for _, k := range e.InheritEnv {
		seen[k] = struct{}{}
	}
	for _, k := range keys {
		if k == "" {
			continue
		}
		if _, ok := seen[k]; ok {
			continue
		}
		seen[k] = struct{}{}
		e.InheritEnv = append(e.InheritEnv, k)
	}
}

// Execute runs p under its limits. Returns nil error only when the executor
// itself cannot start the call; process non-zero exits and timeouts are
// reported on Result and return nil.
func (e *Executor) Execute(ctx context.Context, p Plan) (*Result, error) {
	if p.Binary == "" {
		return nil, fmt.Errorf("executor: empty binary")
	}
	if p.Limits.Timeout <= 0 {
		return nil, fmt.Errorf("executor: limits.timeout must be > 0")
	}
	if p.Limits.MaxStdoutBytes <= 0 || p.Limits.MaxStderrBytes <= 0 {
		return nil, fmt.Errorf("executor: limits.max_*_bytes must be > 0")
	}

	tctx, cancel := context.WithTimeout(ctx, p.Limits.Timeout)
	defer cancel()

	cmd := exec.Command(p.Binary, p.Argv...)
	cmd.Dir = p.CWD
	cmd.Env = e.buildEnv(p.Env)
	applyProcAttr(cmd)
	if p.User != "" {
		if err := applyCredential(cmd, p.User); err != nil {
			return nil, fmt.Errorf("executor: drop privileges to %s: %w", p.User, err)
		}
	}

	// Graceful cancellation: SIGTERM the whole process group first, then
	// SIGKILL that same group after CancelGrace. WaitDelay separately bounds
	// descendants that outlive the leader while retaining its output pipes.
	grace := p.CancelGrace
	if grace <= 0 {
		grace = DefaultCancelGrace
	}
	cmd.WaitDelay = grace

	stdoutPipe, stdoutRelay := io.Pipe()
	stderrPipe, stderrRelay := io.Pipe()
	cmd.Stdout = stdoutRelay
	cmd.Stderr = stderrRelay

	res := &Result{
		Binary:       p.Binary,
		Argv:         append([]string(nil), p.Argv...),
		CWD:          p.CWD,
		EnvKeys:      envKeys(cmd.Env),
		ScriptSHA256: p.ScriptSHA256,
	}

	start := time.Now()
	if err := cmd.Start(); err != nil {
		_ = stdoutRelay.Close()
		_ = stderrRelay.Close()
		_ = stdoutPipe.Close()
		_ = stderrPipe.Close()
		res.Status = StatusFailed
		res.ExitCode = -1
		res.StartError = err.Error()
		res.DurationMS = time.Since(start).Milliseconds()
		res.ArgvSHA256 = sha256Hex(strings.Join(append([]string{p.Binary}, p.Argv...), "\x00"))
		return res, nil
	}
	lifecycle := &processLifecycle{pid: cmd.Process.Pid}
	processFinished := make(chan struct{})
	watcherDone := make(chan struct{})
	go func() {
		defer close(watcherDone)
		lifecycle.watch(tctx, grace, processFinished)
	}()

	var (
		wg                   sync.WaitGroup
		outResult, errResult streamResult
		outErr, errErr       error
	)
	wg.Add(2)
	go func() {
		defer wg.Done()
		defer stdoutPipe.Close()
		outResult, outErr = streamPipe(stdoutPipe, p.Limits.MaxStdoutBytes, StreamStdout, p.OnChunk)
	}()
	go func() {
		defer wg.Done()
		defer stderrPipe.Close()
		errResult, errErr = streamPipe(stderrPipe, p.Limits.MaxStderrBytes, StreamStderr, p.OnChunk)
	}()

	runErr := cmd.Wait()
	if errors.Is(runErr, exec.ErrWaitDelay) {
		// The leader exited but a descendant retained an output descriptor.
		// WaitDelay closed the Cmd-owned pipe; remove the surviving group too.
		lifecycle.signal(syscall.SIGKILL)
	}
	lifecycle.finish()
	close(processFinished)
	<-watcherDone
	_ = stdoutRelay.Close()
	_ = stderrRelay.Close()
	wg.Wait()
	elapsed := time.Since(start)

	timedOut := errors.Is(tctx.Err(), context.DeadlineExceeded)

	res.Stdout = string(outResult.captured)
	res.Stderr = string(errResult.captured)
	res.StdoutBytes = outResult.totalBytes
	res.StderrBytes = errResult.totalBytes
	res.StdoutSHA256 = outResult.sha256
	res.StderrSHA256 = errResult.sha256
	res.Truncated = Truncated{Stdout: outResult.truncated, Stderr: errResult.truncated}
	res.DurationMS = elapsed.Milliseconds()
	res.TimedOut = timedOut
	res.ArgvSHA256 = sha256Hex(strings.Join(append([]string{p.Binary}, p.Argv...), "\x00"))

	switch {
	case outErr != nil || errErr != nil:
		// rare — bufio I/O error from the pipe. Treat as failed.
		res.Status = StatusFailed
		res.ExitCode = -1
		first := outErr
		if first == nil {
			first = errErr
		}
		res.StartError = first.Error()
	case runErr == nil:
		res.Status = StatusOK
		res.ExitCode = 0
	case timedOut:
		res.Status = StatusTimeout
		var exitErr *exec.ExitError
		if errors.As(runErr, &exitErr) {
			res.ExitCode = exitErr.ExitCode()
		} else {
			res.ExitCode = -1
		}
	default:
		var exitErr *exec.ExitError
		if errors.As(runErr, &exitErr) {
			res.Status = StatusNonZero
			res.ExitCode = exitErr.ExitCode()
		} else {
			res.Status = StatusFailed
			res.ExitCode = -1
			res.StartError = runErr.Error()
		}
	}
	return res, nil
}

func (e *Executor) buildEnv(explicit map[string]string) []string {
	keys := make([]string, 0, len(explicit))
	for k := range explicit {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	out := make([]string, 0, len(explicit)+len(e.InheritEnv))
	seen := make(map[string]struct{}, len(explicit))
	for _, k := range keys {
		out = append(out, k+"="+explicit[k])
		seen[k] = struct{}{}
	}
	for _, k := range e.InheritEnv {
		if _, ok := seen[k]; ok {
			continue
		}
		if v, ok := os.LookupEnv(k); ok {
			out = append(out, k+"="+v)
		}
	}
	return out
}

func envKeys(env []string) []string {
	out := make([]string, 0, len(env))
	for _, kv := range env {
		if i := strings.IndexByte(kv, '='); i >= 0 {
			out = append(out, kv[:i])
		}
	}
	return out
}

func sha256Hex(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}

// streamResult is the per-stream summary returned to Execute.
type streamResult struct {
	captured   []byte
	totalBytes int
	sha256     string
	truncated  bool
}

// streamReaderBuf is the bufio buffer size for streaming child output.
// Default bufio is 4 KiB which fragments long lines (e.g., a JSON log
// line from a chatty action) into multiple `action_progress` chunks.
// 64 KiB matches the kernel pipe buffer on most Linuxes and covers the
// vast majority of single lines without artificial splitting.
const streamReaderBuf = 64 * 1024

// streamPipe drains r line-by-line. Hashes are computed over the full
// stream regardless of truncation. Bytes past the size limit are dropped
// but counted (and truncated=true). When onChunk is non-nil, completed
// lines are pushed to it instead of being captured.
//
// A final partial line (no trailing newline at EOF) is still shipped. A line
// longer than the read buffer is processed in buffer-sized pieces, so a child
// emitting a huge newline-free blob can't force one unbounded allocation.
func streamPipe(r io.Reader, limit int, stream Stream, onChunk func(Stream, []byte)) (streamResult, error) {
	br := bufio.NewReaderSize(r, streamReaderBuf)
	h := sha256.New()
	var captured []byte
	if onChunk == nil {
		captured = make([]byte, 0, 4096)
	}
	written := 0
	total := 0
	truncated := false
	for {
		line, err := br.ReadSlice('\n')
		if err == bufio.ErrBufferFull {
			// A line longer than the read buffer: ship/hash THIS bounded piece and
			// keep reading — never accumulate a whole (possibly unbounded, attacker-
			// influenced) line in RAM. ReadSlice's slice is transient, but `ship` and
			// the hash both copy, so processing it here is safe.
			err = nil
		}
		if len(line) > 0 {
			h.Write(line)
			total += len(line)
			remaining := limit - written
			switch {
			case remaining <= 0:
				truncated = true
			case len(line) > remaining:
				ship(line[:remaining], stream, onChunk, &captured)
				written += remaining
				truncated = true
			default:
				ship(line, stream, onChunk, &captured)
				written += len(line)
			}
		}
		if err != nil {
			if err == io.EOF {
				break
			}
			return streamResult{
				captured:   captured,
				totalBytes: total,
				sha256:     hashHex(h),
				truncated:  truncated,
			}, err
		}
	}
	return streamResult{
		captured:   captured,
		totalBytes: total,
		sha256:     hashHex(h),
		truncated:  truncated,
	}, nil
}

func ship(line []byte, stream Stream, onChunk func(Stream, []byte), captured *[]byte) {
	if onChunk != nil {
		buf := make([]byte, len(line))
		copy(buf, line)
		onChunk(stream, buf)
		return
	}
	*captured = append(*captured, line...)
}

func hashHex(h hash.Hash) string { return hex.EncodeToString(h.Sum(nil)) }
