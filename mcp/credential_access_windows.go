//go:build windows

package main

import (
	"errors"
	"fmt"
	"os"
	"strings"
	"syscall"
	"unsafe"
)

const (
	credentialDACLInformation          = 0x00000004
	credentialProtectedDACLInformation = 0x80000000
	credentialReadControl              = 0x00020000
	credentialWriteDACL                = 0x00040000
	credentialSEFileObject             = 1
	credentialSDDLRevision             = 1
)

var (
	credentialAdvapi32                  = syscall.NewLazyDLL("advapi32.dll")
	credentialConvertSDDL               = credentialAdvapi32.NewProc("ConvertStringSecurityDescriptorToSecurityDescriptorW")
	credentialConvertSecurityDescriptor = credentialAdvapi32.NewProc("ConvertSecurityDescriptorToStringSecurityDescriptorW")
	credentialGetSecurityDescriptorDACL = credentialAdvapi32.NewProc("GetSecurityDescriptorDacl")
	credentialGetSecurityInfo           = credentialAdvapi32.NewProc("GetSecurityInfo")
	credentialSetSecurityInfo           = credentialAdvapi32.NewProc("SetSecurityInfo")
)

func secureCredentialDirectoryAccess(path string) (*os.File, error) {
	file, err := openWindowsCredentialObject(path, true, credentialReadControl|credentialWriteDACL)
	if err != nil {
		return nil, err
	}
	if err := setWindowsCredentialDirectoryACL(syscall.Handle(file.Fd())); err != nil {
		_ = file.Close()
		return nil, err
	}
	if err := validateWindowsCredentialACL(syscall.Handle(file.Fd())); err != nil {
		_ = file.Close()
		return nil, err
	}
	return file, nil
}

func validateCredentialTempFileAccess(file *os.File) error {
	return validateWindowsCredentialACL(syscall.Handle(file.Fd()))
}

func validateCredentialFileAccess(path string, _ os.FileInfo) error {
	file, err := openWindowsCredentialObject(path, false, credentialReadControl)
	if err != nil {
		return err
	}
	defer file.Close()
	return validateWindowsCredentialACL(syscall.Handle(file.Fd()))
}

func validateCredentialDirectoryAccess(path string, _ os.FileInfo) error {
	file, err := openWindowsCredentialObject(path, true, credentialReadControl)
	if err != nil {
		return err
	}
	defer file.Close()
	return validateWindowsCredentialACL(syscall.Handle(file.Fd()))
}

func openWindowsCredentialObject(path string, directory bool, access uint32) (*os.File, error) {
	name, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	handle, err := syscall.CreateFile(
		name,
		access,
		syscall.FILE_SHARE_READ|syscall.FILE_SHARE_WRITE|syscall.FILE_SHARE_DELETE,
		nil,
		syscall.OPEN_EXISTING,
		syscall.FILE_FLAG_OPEN_REPARSE_POINT|syscall.FILE_FLAG_BACKUP_SEMANTICS,
		0,
	)
	if err != nil {
		return nil, err
	}
	var info syscall.ByHandleFileInformation
	if err := syscall.GetFileInformationByHandle(handle, &info); err != nil {
		_ = syscall.CloseHandle(handle)
		return nil, err
	}
	if info.FileAttributes&syscall.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
		_ = syscall.CloseHandle(handle)
		return nil, errors.New("reparse points are not allowed")
	}
	isDirectory := info.FileAttributes&syscall.FILE_ATTRIBUTE_DIRECTORY != 0
	if isDirectory != directory {
		_ = syscall.CloseHandle(handle)
		if directory {
			return nil, errors.New("path is not a directory")
		}
		return nil, errors.New("path is not a regular file")
	}
	file := os.NewFile(uintptr(handle), path)
	if file == nil {
		_ = syscall.CloseHandle(handle)
		return nil, errors.New("open credential object")
	}
	return file, nil
}

func setWindowsCredentialDirectoryACL(handle syscall.Handle) error {
	sid, err := currentWindowsUserSID()
	if err != nil {
		return err
	}
	sddl := "D:P" +
		"(A;OICI;FA;;;SY)" +
		"(A;OICI;FA;;;BA)" +
		"(A;OICI;FA;;;" + sid + ")"
	return setWindowsCredentialACL(handle, sddl)
}

func setWindowsCredentialACL(handle syscall.Handle, sddl string) error {
	descriptor, err := securityDescriptorFromString(sddl)
	if err != nil {
		return err
	}
	defer localFree(descriptor)

	var present int32
	var defaulted int32
	var dacl uintptr
	result, _, callErr := credentialGetSecurityDescriptorDACL.Call(
		descriptor,
		uintptr(unsafe.Pointer(&present)),
		uintptr(unsafe.Pointer(&dacl)),
		uintptr(unsafe.Pointer(&defaulted)),
	)
	if result == 0 {
		return windowsCallError("read credential DACL", callErr)
	}
	if present == 0 || dacl == 0 {
		return errors.New("credential DACL is missing")
	}
	result, _, _ = credentialSetSecurityInfo.Call(
		uintptr(handle),
		credentialSEFileObject,
		credentialDACLInformation|credentialProtectedDACLInformation,
		0,
		0,
		dacl,
		0,
	)
	if result != 0 {
		return fmt.Errorf("set credential DACL: %w", syscall.Errno(result))
	}
	return nil
}

func validateWindowsCredentialACL(handle syscall.Handle) error {
	var descriptor uintptr
	result, _, _ := credentialGetSecurityInfo.Call(
		uintptr(handle),
		credentialSEFileObject,
		credentialDACLInformation,
		0,
		0,
		0,
		0,
		uintptr(unsafe.Pointer(&descriptor)),
	)
	if result != 0 {
		return fmt.Errorf("read credential DACL: %w", syscall.Errno(result))
	}
	if descriptor == 0 {
		return errors.New("credential DACL is missing")
	}
	defer localFree(descriptor)
	sddl, err := securityDescriptorString(descriptor)
	if err != nil {
		return err
	}
	sid, err := currentWindowsUserSID()
	if err != nil {
		return err
	}
	if err := validateWindowsCredentialSDDL(sddl, sid); err != nil {
		return fmt.Errorf("DACL is not owner-only: %w", err)
	}
	return nil
}

func currentWindowsUserSID() (string, error) {
	token, err := syscall.OpenCurrentProcessToken()
	if err != nil {
		return "", fmt.Errorf("open process token: %w", err)
	}
	defer token.Close()
	user, err := token.GetTokenUser()
	if err != nil {
		return "", fmt.Errorf("read process token user: %w", err)
	}
	sid, err := user.User.Sid.String()
	if err != nil {
		return "", fmt.Errorf("format process token user SID: %w", err)
	}
	return sid, nil
}

func securityDescriptorFromString(sddl string) (uintptr, error) {
	encoded, err := syscall.UTF16PtrFromString(sddl)
	if err != nil {
		return 0, err
	}
	var descriptor uintptr
	result, _, callErr := credentialConvertSDDL.Call(
		uintptr(unsafe.Pointer(encoded)),
		credentialSDDLRevision,
		uintptr(unsafe.Pointer(&descriptor)),
		0,
	)
	if result == 0 {
		return 0, windowsCallError("parse credential DACL", callErr)
	}
	return descriptor, nil
}

func securityDescriptorString(descriptor uintptr) (string, error) {
	var encoded *uint16
	var length uint32
	result, _, callErr := credentialConvertSecurityDescriptor.Call(
		descriptor,
		credentialSDDLRevision,
		credentialDACLInformation,
		uintptr(unsafe.Pointer(&encoded)),
		uintptr(unsafe.Pointer(&length)),
	)
	if result == 0 {
		return "", windowsCallError("format credential DACL", callErr)
	}
	if encoded == nil {
		return "", errors.New("format credential DACL: empty result")
	}
	defer localFree(uintptr(unsafe.Pointer(encoded)))
	return syscall.UTF16ToString(unsafe.Slice(encoded, length)), nil
}

func validateWindowsCredentialSDDL(sddl, currentSID string) error {
	currentTrustee, err := canonicalWindowsCredentialTrustee(currentSID)
	if err != nil {
		return fmt.Errorf("canonicalize current user SID: %w", err)
	}
	if !strings.HasPrefix(sddl, "D:") {
		return errors.New("DACL is missing")
	}
	firstACE := strings.IndexByte(sddl, '(')
	if firstACE < 0 {
		return errors.New("DACL has no access entries")
	}
	flags := sddl[len("D:"):firstACE]
	if strings.Contains(flags, "NO_ACCESS_CONTROL") {
		return errors.New("DACL grants unrestricted access")
	}

	want := map[string]bool{
		"SY":           false,
		"BA":           false,
		currentSID:     false,
		"S-1-5-18":     false,
		"S-1-5-32-544": false,
	}
	aliases := map[string]string{
		"S-1-5-18":     "SY",
		"S-1-5-32-544": "BA",
		currentTrustee: currentSID,
	}
	seen := map[string]bool{}
	rest := sddl[firstACE:]
	for rest != "" {
		if rest[0] != '(' {
			return errors.New("DACL contains unsupported data")
		}
		end := strings.IndexByte(rest, ')')
		if end < 0 {
			return errors.New("DACL contains an incomplete access entry")
		}
		fields := strings.Split(rest[1:end], ";")
		if len(fields) != 6 || fields[0] != "A" || fields[2] != "FA" || fields[3] != "" || fields[4] != "" {
			return errors.New("DACL contains an unsupported access entry")
		}
		if strings.Contains(fields[1], "IO") {
			return errors.New("DACL contains an inherit-only access entry")
		}
		sid := fields[5]
		if alias := aliases[sid]; alias != "" {
			sid = alias
		}
		if _, ok := want[sid]; !ok || seen[sid] {
			return fmt.Errorf("DACL grants access to unexpected or duplicate SID %s", fields[5])
		}
		seen[sid] = true
		rest = rest[end+1:]
	}
	for _, sid := range []string{"SY", "BA", currentSID} {
		if !seen[sid] {
			return fmt.Errorf("DACL does not grant full access to %s", sid)
		}
	}
	if len(seen) != 3 {
		return errors.New("DACL has an unexpected number of access entries")
	}
	return nil
}

// Windows may serialize a numeric well-known SID with its SDDL token. In
// particular, the built-in local Administrator account becomes LA. Derive the
// current token's spelling through the same API instead of treating every LA
// principal as the caller or maintaining a broader alias allowlist.
func canonicalWindowsCredentialTrustee(sid string) (string, error) {
	descriptor, err := securityDescriptorFromString("D:P(A;;FA;;;" + sid + ")")
	if err != nil {
		return "", err
	}
	defer localFree(descriptor)

	sddl, err := securityDescriptorString(descriptor)
	if err != nil {
		return "", err
	}
	start := strings.IndexByte(sddl, '(')
	end := strings.IndexByte(sddl, ')')
	if start < 0 || end <= start {
		return "", errors.New("canonical DACL has no access entry")
	}
	fields := strings.Split(sddl[start+1:end], ";")
	if len(fields) != 6 || fields[5] == "" {
		return "", errors.New("canonical DACL has an invalid trustee")
	}
	return fields[5], nil
}

func localFree(pointer uintptr) {
	if pointer != 0 {
		_, _ = syscall.LocalFree(syscall.Handle(pointer))
	}
}

func windowsCallError(operation string, err error) error {
	if err == nil || errors.Is(err, syscall.Errno(0)) {
		err = syscall.EINVAL
	}
	return fmt.Errorf("%s: %w", operation, err)
}
