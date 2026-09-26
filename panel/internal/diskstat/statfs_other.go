//go:build !linux

package diskstat

// Statfs is only implemented on Linux (the panel always runs in a Linux container).
func Statfs(string) (Usage, error) { return Usage{}, ErrUnsupported }
