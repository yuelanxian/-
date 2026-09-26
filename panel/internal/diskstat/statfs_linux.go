//go:build linux

package diskstat

import (
	"fmt"
	"syscall"
)

// Statfs returns usage of the filesystem containing p (like df).
func Statfs(p string) (Usage, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(p, &st); err != nil {
		return Usage{}, err
	}
	bs := uint64(st.Frsize)
	if bs == 0 {
		bs = uint64(st.Bsize)
	}
	u := Usage{
		Total: st.Blocks * bs,
		Free:  st.Bavail * bs,
		Used:  (st.Blocks - st.Bfree) * bs,
	}
	if st.Fsid.X__val[0] != 0 || st.Fsid.X__val[1] != 0 {
		u.FSID = fmt.Sprintf("%x:%x", uint32(st.Fsid.X__val[0]), uint32(st.Fsid.X__val[1]))
		u.Key = "fsid:" + u.FSID + fmt.Sprintf(":%d", st.Blocks)
	} else if st.Blocks > 0 {
		u.Key = fmt.Sprintf("size:%d:%d:%d", st.Blocks, st.Bfree, bs)
	}
	return u, nil
}
