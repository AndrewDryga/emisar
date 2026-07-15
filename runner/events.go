package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/andrewdryga/emisar/runner/internal/audit"
)

func eventsCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "events",
		Short: "Inspect the local JSONL event log",
		Long: `Local JSONL events are intended for on-host forensics. The cloud
control plane is the system of record for fleet audit; for cluster-wide
queries use the cloud UI.`,
	}
	cmd.AddCommand(eventsTailCmd())
	cmd.AddCommand(eventsCatCmd())
	cmd.AddCommand(eventsGrepCmd())
	return cmd
}

func openJSONL() (*os.File, string, error) {
	cfg, err := loadConfig()
	if err != nil {
		return nil, "", err
	}
	f, err := os.Open(cfg.Events.JSONLPath)
	if err != nil {
		return nil, "", fmt.Errorf("open jsonl: %w", err)
	}
	return f, cfg.Events.JSONLPath, nil
}

func eventsTailCmd() *cobra.Command {
	var follow bool
	cmd := &cobra.Command{
		Use:   "tail",
		Short: "Print the last N events; optionally follow new ones",
		RunE: func(cmd *cobra.Command, _ []string) error {
			n, _ := cmd.Flags().GetInt("lines")
			if n < 0 {
				return fmt.Errorf("--lines must be non-negative")
			}
			f, path, err := openJSONL()
			if err != nil {
				return err
			}
			lines, err := lastNLines(f, n)
			if err != nil {
				_ = f.Close()
				return err
			}
			for _, l := range lines {
				fmt.Println(l)
			}
			if !follow {
				_ = f.Close()
				return nil
			}
			return followJSONL(cmd.Context(), path, f, os.Stdout)
		},
	}
	cmd.Flags().Int("lines", 50, "number of trailing events to print")
	cmd.Flags().BoolVarP(&follow, "follow", "f", false, "follow new events as they arrive")
	return cmd
}

func eventsCatCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "cat",
		Short: "Print the entire JSONL log to stdout",
		RunE: func(_ *cobra.Command, _ []string) error {
			f, _, err := openJSONL()
			if err != nil {
				return err
			}
			defer f.Close()
			_, err = io.Copy(os.Stdout, f)
			return err
		},
	}
}

func eventsGrepCmd() *cobra.Command {
	var (
		actionID string
		actor    string
		eventID  string
	)
	cmd := &cobra.Command{
		Use:   "grep",
		Short: "Filter the JSONL log by a few common fields",
		RunE: func(_ *cobra.Command, _ []string) error {
			f, _, err := openJSONL()
			if err != nil {
				return err
			}
			defer f.Close()
			s := bufio.NewScanner(f)
			s.Buffer(make([]byte, 64*1024), 4*1024*1024)
			for s.Scan() {
				line := s.Bytes()
				var ev audit.Event
				if err := json.Unmarshal(line, &ev); err != nil {
					continue
				}
				if actionID != "" && ev.ActionID != actionID {
					continue
				}
				if eventID != "" && ev.EventID != eventID {
					continue
				}
				if actor != "" && !strings.Contains(ev.Caller.ControlPlaneRequestID, actor) {
					continue
				}
				fmt.Println(string(line))
			}
			return s.Err()
		},
	}
	cmd.Flags().StringVar(&actionID, "action", "", "filter by action id")
	cmd.Flags().StringVar(&actor, "caller", "", "substring match on caller control_plane_request_id")
	cmd.Flags().StringVar(&eventID, "event", "", "match a specific event id")
	return cmd
}

// lastNLines returns the trailing n lines of a file as strings. Reads from
// the end in 8 KiB chunks to avoid loading the whole file. Acceptable for
// human-scale JSONL logs.
func lastNLines(f *os.File, n int) ([]string, error) {
	if n < 0 {
		return nil, fmt.Errorf("line count must be non-negative")
	}
	if n == 0 {
		return nil, nil
	}
	stat, err := f.Stat()
	if err != nil {
		return nil, err
	}
	size := stat.Size()
	const chunk = 8 * 1024
	var buf []byte
	pos := size
	newlines := 0
	for pos > 0 && newlines <= n {
		read := int64(chunk)
		if pos < read {
			read = pos
		}
		pos -= read
		seg := make([]byte, read)
		if _, err := f.ReadAt(seg, pos); err != nil {
			return nil, err
		}
		buf = append(seg, buf...)
		newlines = 0
		for _, b := range buf {
			if b == '\n' {
				newlines++
			}
		}
	}
	lines := strings.Split(strings.TrimRight(string(buf), "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return lines, nil
}

func followJSONL(ctx context.Context, path string, f *os.File, out io.Writer) error {
	defer func() { _ = f.Close() }()
	pos, err := f.Seek(0, io.SeekEnd)
	if err != nil {
		return err
	}
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
		}

		f, pos, err = pollFollowedJSONL(path, f, out, pos)
		if err != nil {
			return err
		}
	}
}

func pollFollowedJSONL(path string, f *os.File, out io.Writer, pos int64) (*os.File, int64, error) {
	pathInfo, err := os.Stat(path)
	if os.IsNotExist(err) {
		return f, pos, nil
	}
	if err != nil {
		return f, pos, err
	}
	openInfo, err := f.Stat()
	if err != nil {
		return f, pos, err
	}
	if !os.SameFile(pathInfo, openInfo) {
		pos, err = copyAppendedJSONL(f, out, pos, openInfo.Size())
		if err != nil {
			return f, pos, err
		}
		next, openErr := os.Open(path)
		if os.IsNotExist(openErr) {
			return f, pos, nil
		}
		if openErr != nil {
			return f, pos, openErr
		}
		_ = f.Close()
		f = next
		pos = 0
		pathInfo, err = f.Stat()
		if err != nil {
			return f, pos, err
		}
	}

	pos, err = copyAppendedJSONL(f, out, pos, pathInfo.Size())
	return f, pos, err
}

func copyAppendedJSONL(f *os.File, out io.Writer, pos, size int64) (int64, error) {
	if size < pos {
		pos = 0
	}
	if size == pos {
		return pos, nil
	}
	if _, err := f.Seek(pos, io.SeekStart); err != nil {
		return pos, err
	}
	written, err := io.Copy(out, f)
	if err != nil {
		return pos, err
	}
	return pos + written, nil
}
