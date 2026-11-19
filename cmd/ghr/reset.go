package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

// cleanRoots are the directories the runner user can write in the image
// (`find / -xdev -writable` as uid 1001), besides the runner directory.
// A restarted container keeps its writable layer, so they are emptied on
// every start: nothing a job left behind reaches the next job.
var cleanRoots = []string{"/home/runner", "/tmp", "/var/tmp", "/_work", "/opt/hostedtoolcache"}

// resetState removes what the runner user may have left:
//   - in runnerDir, every top-level entry not owned by root (registration
//     files, _diag, anything a job created; bin/ and externals/ are root's);
//   - the contents of each of roots, keeping the directory itself.
//
// It never follows symlinks and never descends into another mount: a shared
// bind mount (e.g. /tmp/runners) is left alone unless it is itself in roots.
func resetState(runnerDir string, roots, mounts []string) error {
	var errs []error
	if runnerDir != "" {
		entries, err := os.ReadDir(runnerDir)
		if err != nil {
			return err
		}
		for _, e := range entries {
			p := filepath.Join(runnerDir, e.Name())
			st, err := os.Lstat(p)
			if err != nil {
				errs = append(errs, err)
				continue
			}
			if st.Sys().(*syscall.Stat_t).Uid != 0 {
				errs = append(errs, removeTree(p, mounts))
			}
		}
	}
	for _, root := range roots {
		st, err := os.Lstat(root)
		switch {
		case errors.Is(err, fs.ErrNotExist):
			continue
		case err != nil:
			errs = append(errs, err)
			continue
		case !st.IsDir():
			// Not a real directory (e.g. a symlink a job planted where its
			// work directory was): remove the entry itself, nothing behind it.
			errs = append(errs, os.Remove(root))
			continue
		}
		entries, err := os.ReadDir(root)
		if err != nil {
			errs = append(errs, err)
			continue
		}
		for _, e := range entries {
			errs = append(errs, removeTree(filepath.Join(root, e.Name()), mounts))
		}
	}
	return errors.Join(errs...)
}

// removeTree is os.RemoveAll that stops at mount points: a mount is left in
// place, and a directory containing one keeps that path to it.
func removeTree(p string, mounts []string) error {
	under := false
	for _, m := range mounts {
		if m == p {
			return nil
		}
		if strings.HasPrefix(m, p+"/") {
			under = true
		}
	}
	if !under {
		return os.RemoveAll(p) // does not follow symlinks
	}
	entries, err := os.ReadDir(p)
	if err != nil {
		return err
	}
	var errs []error
	for _, e := range entries {
		errs = append(errs, removeTree(filepath.Join(p, e.Name()), mounts))
	}
	return errors.Join(errs...)
}

// mountPoints lists this process's mount points.
func mountPoints() ([]string, error) {
	b, err := os.ReadFile("/proc/self/mountinfo")
	if err != nil {
		return nil, fmt.Errorf("read mountinfo: %w", err)
	}
	return parseMountinfo(string(b)), nil
}

// parseMountinfo returns field 5 (the mount point) of each line, with the
// kernel's octal escapes (\040 for a space, ...) decoded.
func parseMountinfo(s string) []string {
	var out []string
	for _, line := range strings.Split(s, "\n") {
		f := strings.Fields(line)
		if len(f) < 5 {
			continue
		}
		out = append(out, unescapeOctal(f[4]))
	}
	return out
}

func unescapeOctal(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+4 <= len(s) {
			if n, err := strconv.ParseUint(s[i+1:i+4], 8, 8); err == nil {
				b.WriteByte(byte(n))
				i += 3
				continue
			}
		}
		b.WriteByte(s[i])
	}
	return b.String()
}
