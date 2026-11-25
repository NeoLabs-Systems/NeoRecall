//go:build windows

package embeddings

import "syscall"

func openSharedLib(name string) (uintptr, error) {
	h, err := syscall.LoadLibrary(name)
	return uintptr(h), err
}
