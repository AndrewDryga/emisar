package audit

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// A daemon and an operator's local action/pack verification open the same
// journal. Each must continue the last writer's chain and follow its rotations.
func TestJSONL_SharedWriters(t *testing.T) {
	for _, threshold := range []int64{0, 500} {
		t.Run(fmt.Sprintf("rotation_%d", threshold), func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "events.jsonl")
			opts := JSONLOptions{MaxSizeBytes: threshold, MaxBackups: 30}
			first, err := OpenJSONL(path, opts)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = first.Close() })
			second, err := OpenJSONL(path, opts)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = second.Close() })
			writers := []*JSONLSink{first, second}
			for i := 0; i < 30; i++ {
				if err := writers[i%2].Write(context.Background(), Event{
					EventID: fmt.Sprintf("event-%d", i), Type: EventExecutionCompleted,
				}); err != nil {
					t.Fatal(err)
				}
			}
			assertSharedJournal(t, path, 30)
		})
	}
}

func TestJSONL_SharedProcess(t *testing.T) {
	if path := os.Getenv("EMISAR_TEST_SHARED_JOURNAL"); path != "" {
		sink, err := OpenJSONL(path, JSONLOptions{MaxSizeBytes: 500, MaxBackups: 60})
		if err != nil {
			t.Fatal(err)
		}
		defer sink.Close()
		fmt.Println("ready")
		input := bufio.NewScanner(os.Stdin)
		if !input.Scan() || input.Text() != "start" {
			t.Fatal("missing parent handshake")
		}
		for i := 0; i < 30; i++ {
			if err := sink.Write(context.Background(), Event{
				EventID: fmt.Sprintf("child-%d", i), Type: EventExecutionCompleted,
			}); err != nil {
				t.Fatal(err)
			}
		}
		return
	}
	path := filepath.Join(t.TempDir(), "events.jsonl")
	parent, err := OpenJSONL(path, JSONLOptions{MaxSizeBytes: 500, MaxBackups: 60})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = parent.Close() })
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestJSONL_SharedProcess$")
	cmd.Env = append(os.Environ(), "EMISAR_TEST_SHARED_JOURNAL="+path)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	input, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	output, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = input.Close()
		cancel()
		_ = cmd.Wait()
	})
	reader := bufio.NewScanner(output)
	if !reader.Scan() || reader.Text() != "ready" {
		t.Fatalf("child did not open journal: %s", stderr.String())
	}
	if _, err := fmt.Fprintln(input, "start"); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 30; i++ {
		if err := parent.Write(context.Background(), Event{
			EventID: fmt.Sprintf("parent-%d", i), Type: EventExecutionCompleted,
		}); err != nil {
			t.Fatal(err)
		}
	}
	if err := cmd.Wait(); err != nil {
		t.Fatalf("child write failed: %v: %s", err, stderr.String())
	}
	assertSharedJournal(t, path, 60)
}

type pausedAppendFile struct {
	auditFile
	started chan struct{}
	resume  chan struct{}
}

func (f pausedAppendFile) Write(line []byte) (int, error) {
	n, err := f.auditFile.Write(line[:len(line)-1])
	if err != nil {
		return n, err
	}
	close(f.started)
	<-f.resume
	m, err := f.auditFile.Write(line[len(line)-1:])
	return n + m, err
}

// Opening a second sink must not mistake an in-progress append for a torn
// crash tail and truncate it. Hold the write before its final newline.
func TestJSONL_OpenWaitsForActiveAppend(t *testing.T) {
	path := filepath.Join(t.TempDir(), "events.jsonl")
	sink, err := OpenJSONL(path, JSONLOptions{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = sink.Close() })
	paused := pausedAppendFile{sink.f, make(chan struct{}), make(chan struct{})}
	var release sync.Once
	resume := func() { release.Do(func() { close(paused.resume) }) }
	t.Cleanup(resume)
	sink.f = paused
	written := make(chan error, 1)
	go func() {
		written <- sink.Write(context.Background(), Event{EventID: "first", Type: EventExecutionCompleted})
	}()
	select {
	case <-paused.started:
	case err := <-written:
		t.Fatalf("initial append ended before the pause: %v", err)
	case <-time.After(30 * time.Second):
		t.Fatal("initial append did not reach the pause")
	}
	opened := make(chan error, 1)
	go func() {
		peer, err := OpenJSONL(path, JSONLOptions{})
		if err == nil {
			err = peer.Write(context.Background(), Event{EventID: "second", Type: EventExecutionCompleted})
			_ = peer.Close()
		}
		opened <- err
	}()
	// A bounded negative wait tests the blocking contract, not service startup
	// speed: until resume, the first append remains deliberately incomplete.
	select {
	case err := <-opened:
		t.Fatalf("peer opened during a partial append: %v", err)
	case <-time.After(100 * time.Millisecond):
	}
	resume()
	if err := <-written; err != nil {
		t.Fatal(err)
	}
	if err := <-opened; err != nil {
		t.Fatal(err)
	}
	assertSharedJournal(t, path, 2)
}

func assertSharedJournal(t *testing.T, path string, count int) {
	t.Helper()
	files := []string{path}
	for i := 1; ; i++ {
		backup := fmt.Sprintf("%s.%d", path, i)
		if _, err := os.Stat(backup); os.IsNotExist(err) {
			break
		} else if err != nil {
			t.Fatal(err)
		}
		files = append(files, backup)
	}
	seen := make(map[string]bool)
	for _, file := range files {
		if err := VerifyChain(file); err != nil {
			t.Errorf("%s: %v", file, err)
		}
		body, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		for _, line := range strings.Split(strings.TrimSpace(string(body)), "\n") {
			var ev Event
			if err := json.Unmarshal([]byte(line), &ev); err != nil {
				t.Fatal(err)
			}
			if seen[ev.EventID] {
				t.Errorf("duplicate event %q", ev.EventID)
			}
			seen[ev.EventID] = true
		}
	}
	if len(seen) != count {
		t.Errorf("retained %d unique events, want %d", len(seen), count)
	}
}
