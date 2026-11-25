//go:build windows

package transcription

import "syscall"

func openSharedLib(name string) (uintptr, error) {
	h, err := syscall.LoadLibrary(name)
	return uintptr(h), err
}
