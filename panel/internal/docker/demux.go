package docker

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
)

// Stream identifiers in the multiplexed attach/logs protocol.
const (
	StreamStdin  = 0
	StreamStdout = 1
	StreamStderr = 2
	StreamSystem = 3
)

// ErrBadFrame is returned for a malformed 8-byte frame header.
var ErrBadFrame = errors.New("docker: malformed log frame header")

// Demux copies a multiplexed Docker log stream (8-byte header per frame:
// [stream, 0, 0, 0, size uint32 big-endian] followed by size bytes) into dst.
// Frames from stdout and stderr are both written; stderr frames are passed to
// onStderr (if non-nil) instead when you need to tell them apart.
func Demux(dst io.Writer, src io.Reader) error {
	return DemuxStreams(dst, dst, src)
}

// DemuxStreams writes stdout frames to stdout and stderr frames to stderr.
func DemuxStreams(stdout, stderr io.Writer, src io.Reader) error {
	var hdr [8]byte
	for {
		if _, err := io.ReadFull(src, hdr[:]); err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			if errors.Is(err, io.ErrUnexpectedEOF) {
				return fmt.Errorf("%w: truncated header", ErrBadFrame)
			}
			return err
		}
		if hdr[1] != 0 || hdr[2] != 0 || hdr[3] != 0 || hdr[0] > StreamSystem {
			return ErrBadFrame
		}
		size := int64(binary.BigEndian.Uint32(hdr[4:8]))
		var w io.Writer
		switch hdr[0] {
		case StreamStdout:
			w = stdout
		case StreamStderr, StreamSystem:
			w = stderr
		default:
			w = io.Discard
		}
		n, err := io.CopyN(w, src, size)
		if err != nil {
			if errors.Is(err, io.EOF) && n < size {
				return fmt.Errorf("%w: truncated frame", ErrBadFrame)
			}
			return err
		}
	}
}

// LooksMultiplexed peeks at the first 8 bytes and reports whether they form a valid frame header.
func LooksMultiplexed(br *bufio.Reader) bool {
	b, err := br.Peek(8)
	if err != nil {
		return false
	}
	return b[0] <= StreamSystem && b[1] == 0 && b[2] == 0 && b[3] == 0
}

// limitWriter fails once more than N bytes have been written.
type limitWriter struct {
	w io.Writer
	n int64
}

var errLimit = errors.New("docker: output limit reached")

func (l *limitWriter) Write(p []byte) (int, error) {
	if int64(len(p)) > l.n {
		k, _ := l.w.Write(p[:l.n])
		l.n -= int64(k)
		return k, errLimit
	}
	k, err := l.w.Write(p)
	l.n -= int64(k)
	return k, err
}
