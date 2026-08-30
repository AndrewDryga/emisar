package selfupdate

import (
	"bufio"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

const receiptLocatorName = ".emisar-install-receipt"

type receipt struct {
	Binary       string
	EtcDir       string
	DataDir      string
	LogDir       string
	ServiceUser  string
	ServiceGroup string
	Init         string
}

func loadReceipt(executable string, trustPath func(string, fs.FileInfo) error) (receipt, error) {
	locator := filepath.Join(filepath.Dir(executable), receiptLocatorName)
	locatorInfo, err := os.Lstat(locator)
	if err != nil {
		return receipt{}, fmt.Errorf("official installer receipt locator is missing beside %s", executable)
	}
	if !locatorInfo.Mode().IsRegular() {
		return receipt{}, errorsForPath(locator, "must be a regular file, not a link")
	}
	if err := trustPath(locator, locatorInfo); err != nil {
		return receipt{}, err
	}
	locatorData, err := os.ReadFile(locator)
	if err != nil {
		return receipt{}, fmt.Errorf("read install receipt locator: %w", err)
	}
	if len(locatorData) > 4096 {
		return receipt{}, errorsForPath(locator, "is too large")
	}
	receiptPath := strings.TrimSpace(string(locatorData))
	if !filepath.IsAbs(receiptPath) || filepath.Clean(receiptPath) != receiptPath {
		return receipt{}, errorsForPath(locator, "does not contain one clean absolute receipt path")
	}

	info, err := os.Lstat(receiptPath)
	if err != nil {
		return receipt{}, fmt.Errorf("official installer receipt is missing at %s", receiptPath)
	}
	if !info.Mode().IsRegular() {
		return receipt{}, errorsForPath(receiptPath, "must be a regular file, not a link")
	}
	if err := trustPath(receiptPath, info); err != nil {
		return receipt{}, err
	}
	executableInfo, err := os.Lstat(executable)
	if err != nil {
		return receipt{}, fmt.Errorf("inspect current executable: %w", err)
	}
	if !executableInfo.Mode().IsRegular() {
		return receipt{}, errorsForPath(executable, "must be a regular file")
	}
	if err := trustPath(executable, executableInfo); err != nil {
		return receipt{}, err
	}

	file, err := os.Open(receiptPath)
	if err != nil {
		return receipt{}, fmt.Errorf("open official installer receipt: %w", err)
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 4096), 32<<10)
	values := map[string]string{}
	for scanner.Scan() {
		line := scanner.Text()
		key, value, ok := strings.Cut(line, "=")
		if !ok || key == "" || value == "" {
			return receipt{}, errorsForPath(receiptPath, "contains a malformed line")
		}
		if _, duplicate := values[key]; duplicate {
			return receipt{}, errorsForPath(receiptPath, "contains duplicate "+key)
		}
		values[key] = value
	}
	if err := scanner.Err(); err != nil {
		return receipt{}, fmt.Errorf("read official installer receipt: %w", err)
	}

	wanted := []string{
		"schema", "manager", "repository", "binary", "etc_dir", "data_dir",
		"log_dir", "service_user", "service_group", "init",
	}
	if len(values) != len(wanted) {
		return receipt{}, errorsForPath(receiptPath, "has an unexpected field set")
	}
	for _, key := range wanted {
		if values[key] == "" {
			return receipt{}, errorsForPath(receiptPath, "is missing "+key)
		}
	}
	// A receipt names the repository its installer served, which during the
	// EmisarHQ transfer window is either spelling of the same repository.
	repositoryOK := values["repository"] == officialRepository ||
		values["repository"] == successorRepository
	if values["schema"] != "1" || values["manager"] != "install.sh" || !repositoryOK {
		return receipt{}, errorsForPath(receiptPath, "was not written by the official installer")
	}
	for _, key := range []string{"binary", "etc_dir", "data_dir", "log_dir"} {
		value := values[key]
		if !filepath.IsAbs(value) || filepath.Clean(value) != value {
			return receipt{}, errorsForPath(receiptPath, key+" is not a clean absolute path")
		}
	}
	receiptBinary, err := filepath.EvalSymlinks(values["binary"])
	if err != nil {
		return receipt{}, fmt.Errorf("resolve receipt binary: %w", err)
	}
	if receiptBinary != executable {
		return receipt{}, errorsForPath(receiptPath, "belongs to a different runner binary")
	}
	if values["init"] != "systemd" && values["init"] != "launchd" && values["init"] != "none" {
		return receipt{}, errorsForPath(receiptPath, "contains an unsupported init manager")
	}
	for _, key := range []string{"service_user", "service_group"} {
		if !safeAccountName(values[key]) {
			return receipt{}, errorsForPath(receiptPath, key+" is unsafe")
		}
	}

	return receipt{
		Binary:       values["binary"],
		EtcDir:       values["etc_dir"],
		DataDir:      values["data_dir"],
		LogDir:       values["log_dir"],
		ServiceUser:  values["service_user"],
		ServiceGroup: values["service_group"],
		Init:         values["init"],
	}, nil
}

func safeAccountName(value string) bool {
	if value == "" || len(value) > 64 {
		return false
	}
	for index, char := range value {
		if (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') ||
			(index > 0 && char >= '0' && char <= '9') || strings.ContainsRune("_.-", char) {
			continue
		}
		return false
	}
	return true
}

func errorsForPath(path, message string) error {
	return fmt.Errorf("%s %s", path, message)
}
