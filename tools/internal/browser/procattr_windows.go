package browser

import "syscall"

func browserSysProcAttr() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{}
}
