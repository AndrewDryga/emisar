package cloud

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"reflect"
	"slices"

	"github.com/andrewdryga/emisar/runner/internal/fsutil"
)

const maxDispatchLogLineBytes = 16 << 20

// A plain snapshot prefix followed by versioned transitions stays in the SAME
// file. Older snapshot-only readers reject a transition, rather than silently
// ignoring a sidecar journal and executing a previously reserved mutation.
type dispatchTransition struct {
	Version int        `json:"dispatch_log_version"`
	Entry   dedupEntry `json:"entry"`
	Evict   string     `json:"evict,omitempty"`
}

type dispatchFile interface {
	Write([]byte) (int, error)
	Sync() error
	Stat() (os.FileInfo, error)
	Truncate(int64) error
	Close() error
}

type dispatchStore struct {
	entries       []dedupEntry
	info          os.FileInfo
	legacy        bool
	needsSnapshot bool
	snapshotBytes int64
	transitions   int
}

func readDispatchStore(path string) (dispatchStore, error) {
	var log dispatchStore
	f, err := openSecureLocalFile(path)
	if err != nil {
		return log, fmt.Errorf("open dispatch log: %w", err)
	}
	defer f.Close()
	log.info, err = f.Stat()
	if err != nil {
		return log, fmt.Errorf("stat dispatch log: %w", err)
	}
	if !log.info.Mode().IsRegular() {
		return log, fmt.Errorf("dispatch log is not a regular file")
	}
	keys := []string{}
	records := map[string]dedupEntry{}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), maxDispatchLogLineBytes)
	var consumed int64
	sc.Split(func(data []byte, atEOF bool) (int, []byte, error) {
		advance, token, splitErr := bufio.ScanLines(data, atEOF)
		consumed += int64(advance)
		return advance, token, splitErr
	})
	lineNumber := 0
	for sc.Scan() {
		lineNumber++
		line := sc.Bytes()
		var fields map[string]json.RawMessage
		if err := json.Unmarshal(line, &fields); err != nil || fields == nil {
			return log, fmt.Errorf("invalid dispatch log entry on line %d", lineNumber)
		}
		if _, tagged := fields["dispatch_log_version"]; tagged {
			transition, err := decodeDispatchTransition(line, fields)
			if err != nil || validateDispatchTransition(records, transition) != nil {
				return log, fmt.Errorf("invalid dispatch log transition on line %d", lineNumber)
			}
			applyDispatchTransition(&keys, records, transition)
			log.transitions++
			continue
		}
		if log.transitions != 0 {
			return log, fmt.Errorf("snapshot after dispatch log transition on line %d", lineNumber)
		}
		entry, legacy, err := decodeDedupEntry(line)
		if err != nil {
			return log, fmt.Errorf("invalid dispatch log entry on line %d", lineNumber)
		}
		if _, duplicate := records[entry.RequestID]; duplicate {
			return log, fmt.Errorf("duplicate dispatch log entry on line %d", lineNumber)
		}
		keys = append(keys, entry.RequestID)
		records[entry.RequestID] = entry
		log.legacy = log.legacy || legacy
		log.snapshotBytes = consumed
	}
	if err := sc.Err(); err != nil {
		return log, fmt.Errorf("read dispatch log: %w", err)
	}
	info, err := f.Stat()
	if err != nil {
		return log, fmt.Errorf("stat dispatch log after reading: %w", err)
	}
	if !sameDispatchFile(log.info, info) {
		return log, fmt.Errorf("dispatch log changed while reading")
	}
	if info.Size() > 0 {
		var last [1]byte
		if _, err := f.ReadAt(last[:], info.Size()-1); err != nil {
			return log, fmt.Errorf("read dispatch log ending: %w", err)
		}
		// The deployed reader accepted a valid last JSON record without LF.
		// Normalize by snapshotting before append; never heal a torn JSON record.
		log.needsSnapshot = last[0] != '\n'
	}
	for _, key := range keys {
		log.entries = append(log.entries, records[key])
	}
	return log, nil
}

func decodeDispatchTransition(line []byte, fields map[string]json.RawMessage) (dispatchTransition, error) {
	var transition dispatchTransition
	if err := validateUniqueJSON(line); err != nil {
		return transition, err
	}
	for key := range fields {
		if key != "dispatch_log_version" && key != "entry" && key != "evict" {
			return transition, fmt.Errorf("unknown dispatch transition field")
		}
	}
	decoder := json.NewDecoder(bytes.NewReader(line))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&transition); err != nil {
		return transition, err
	}
	if _, present := fields["evict"]; present && transition.Evict == "" {
		return transition, fmt.Errorf("empty dispatch eviction")
	}
	return transition, nil
}

func validateDispatchTransition(records map[string]dedupEntry, transition dispatchTransition) error {
	entry := transition.Entry
	if transition.Version != 1 || !validDedupEntry(entry) {
		return fmt.Errorf("invalid dispatch transition")
	}
	previous, exists := records[entry.RequestID]
	if transition.Evict != "" && (entry.State != dispatchReserved ||
		transition.Evict == entry.RequestID || records[transition.Evict].State != dispatchAcknowledged) {
		return fmt.Errorf("invalid dispatch eviction")
	}
	switch entry.State {
	case dispatchReserved:
		if !exists {
			return nil
		}
	case dispatchCompleted:
		if exists && previous.State == dispatchReserved && previous.DispatchSHA256 == entry.DispatchSHA256 {
			return nil
		}
	case dispatchAcknowledged:
		if exists && previous.State == dispatchCompleted && previous.DispatchSHA256 == entry.DispatchSHA256 &&
			reflect.DeepEqual(previous.Result, entry.Result) {
			return nil
		}
	}
	return fmt.Errorf("invalid dispatch state transition")
}

// Only called after validation, and at runtime only after durable commit.
func applyDispatchTransition(keys *[]string, records map[string]dedupEntry, transition dispatchTransition) {
	if transition.Evict != "" {
		index := slices.Index(*keys, transition.Evict)
		*keys = slices.Delete(*keys, index, index+1)
		delete(records, transition.Evict)
	}
	if transition.Entry.State == dispatchReserved {
		*keys = append(*keys, transition.Entry.RequestID)
	}
	records[transition.Entry.RequestID] = transition.Entry
}

func (d *dedupRing) unusableLocked() error {
	if d.loadErr != nil {
		return d.loadErr
	}
	return d.persistErr
}

func (d *dedupRing) commitTransitionLocked(transition dispatchTransition) error {
	if err := validateDispatchTransition(d.records, transition); err != nil {
		return err
	}
	if d.storePath != "" {
		line, err := dispatchLogLine(transition)
		if err != nil {
			return err
		}
		f, err := d.prepareAppendLocked(int64(len(line)))
		if err != nil {
			return err
		}
		defer d.closeDispatchFile(f)
		oldEOF := d.backing.Size()
		if err := writeDispatchLine(f, line); err != nil {
			return d.rollbackAppendLocked(f, oldEOF, err)
		}
		if err := f.Sync(); err != nil {
			return d.rollbackAppendLocked(f, oldEOF, fmt.Errorf("sync dispatch transition: %w", err))
		}
		// The snapshot already made this file's namespace durable. File Sync is
		// the append commit barrier: later stat/close failures cannot roll it back
		// in memory and cause a duplicate strict transition on the next retry.
		info, err := f.Stat()
		if err == nil && (!info.Mode().IsRegular() || !os.SameFile(d.backing, info) || info.Size() != oldEOF+int64(len(line))) {
			err = fmt.Errorf("dispatch log changed during append")
		}
		if err != nil {
			d.needsSnapshot = true
			d.logger.Warn("cloud.dedup_stat_failed_after_commit", "error", err)
		} else {
			d.backing = info
		}
		d.transitionCount++
		d.appendBytes += int64(len(line))
	}
	applyDispatchTransition(&d.keys, d.records, transition)
	return nil
}

func (d *dedupRing) prepareAppendLocked(nextBytes int64) (dispatchFile, error) {
	// One owner writes this store. Check between-operation drift, not a claim
	// to withstand a privileged writer racing every filesystem operation.
	for attempt := 0; attempt < 2; attempt++ {
		if d.needsSnapshot || d.backing == nil ||
			d.transitionCount >= max(64, 3*d.max) ||
			(d.appendBytes > 0 && d.appendBytes+nextBytes > max(int64(1<<20), d.snapshotBytes)) {
			if err := d.writeStore(); err != nil {
				return nil, err
			}
		}
		opener := d.openAppend
		if opener == nil {
			opener = func(path string) (dispatchFile, error) { return openSecureLocalAppend(path) }
		}
		f, err := opener(d.storePath)
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				d.needsSnapshot = true
				continue
			}
			return nil, fmt.Errorf("open dispatch log for append: %w", err)
		}
		info, err := f.Stat()
		if err != nil {
			d.closeDispatchFile(f)
			return nil, fmt.Errorf("stat dispatch log for append: %w", err)
		}
		if !info.Mode().IsRegular() {
			d.closeDispatchFile(f)
			return nil, fmt.Errorf("dispatch log is not a regular file")
		}
		if sameDispatchFile(d.backing, info) {
			return f, nil
		}
		d.closeDispatchFile(f)
		d.needsSnapshot = true
	}
	return nil, fmt.Errorf("dispatch log changed while preparing append")
}

func sameDispatchFile(expected, actual os.FileInfo) bool {
	return expected != nil && actual != nil && os.SameFile(expected, actual) &&
		expected.Size() == actual.Size() && expected.ModTime().Equal(actual.ModTime())
}

func (d *dedupRing) rollbackAppendLocked(f dispatchFile, oldEOF int64, cause error) error {
	rollbackErr := f.Truncate(oldEOF)
	if rollbackErr == nil {
		rollbackErr = f.Sync()
	}
	if rollbackErr != nil {
		d.persistErr = fmt.Errorf("cloud: dispatch log rollback failed; restart required: %w", errors.Join(cause, rollbackErr))
		return d.persistErr
	}
	info, err := f.Stat()
	if err != nil {
		d.needsSnapshot = true
	} else {
		d.backing = info
	}
	return cause
}

func (d *dedupRing) closeDispatchFile(f interface{ Close() error }) {
	if err := f.Close(); err != nil {
		d.logger.Warn("cloud.dedup_close_failed", "error", err)
	}
}

// A failed replacement may already have renamed its snapshot. Since the
// snapshot contains only committed memory, retrying a complete replacement is
// safe without inferring whether the failure preceded or followed rename.
func (d *dedupRing) writeStore() error {
	if d.storePath == "" {
		return nil
	}
	d.needsSnapshot = true
	if info, err := os.Lstat(d.storePath); err == nil {
		if !info.Mode().IsRegular() {
			return fmt.Errorf("dispatch log is not a regular file")
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("stat dispatch log before snapshot: %w", err)
	}
	replace := d.replaceFile
	if replace == nil {
		replace = fsutil.ReplaceFile
	}
	var written int64
	if err := replace(d.storePath, func(w io.Writer) error {
		for _, key := range d.keys {
			line, err := dispatchLogLine(d.records[key])
			if err != nil {
				return err
			}
			if err := writeDispatchLine(w, line); err != nil {
				return err
			}
			written += int64(len(line))
		}
		return nil
	}); err != nil {
		return err
	}
	f, err := openSecureLocalFile(d.storePath)
	if err != nil {
		return fmt.Errorf("open dispatch snapshot: %w", err)
	}
	defer d.closeDispatchFile(f)
	info, err := f.Stat()
	if err != nil {
		return fmt.Errorf("stat dispatch snapshot: %w", err)
	}
	if !info.Mode().IsRegular() || info.Size() != written {
		return fmt.Errorf("dispatch snapshot changed during replacement")
	}
	d.backing = info
	d.needsSnapshot = false
	d.snapshotBytes = written
	d.appendBytes = 0
	d.transitionCount = 0
	return nil
}

func dispatchLogLine(value any) ([]byte, error) {
	line, err := json.Marshal(value)
	if err != nil {
		return nil, err
	}
	if len(line)+1 > maxDispatchLogLineBytes {
		return nil, fmt.Errorf("dispatch log record exceeds %d bytes", maxDispatchLogLineBytes)
	}
	return append(line, '\n'), nil
}

func writeDispatchLine(w io.Writer, line []byte) error {
	n, err := w.Write(line)
	if err != nil {
		return fmt.Errorf("write dispatch log: %w", err)
	}
	if n != len(line) {
		return fmt.Errorf("write dispatch log: %w", io.ErrShortWrite)
	}
	return nil
}
