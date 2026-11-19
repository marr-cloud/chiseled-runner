package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func touch(t *testing.T, p string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func exists(p string) bool { _, err := os.Lstat(p); return err == nil }

func TestEmptyDirKeepsTheDirAndNeverFollowsSymlinks(t *testing.T) {
	root := filepath.Join(t.TempDir(), "home")
	outside := t.TempDir()
	touch(t, filepath.Join(outside, "keep"))
	touch(t, filepath.Join(root, ".bashrc"))
	touch(t, filepath.Join(root, "a", "b", "c"))
	if err := os.Symlink(outside, filepath.Join(root, "link")); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(root, 0o750); err != nil {
		t.Fatal(err)
	}

	if err := resetState("", []string{root}, nil); err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatalf("root dir removed: %v", err)
	}
	if len(entries) != 0 {
		t.Errorf("left behind: %v", entries)
	}
	if st, _ := os.Stat(root); st.Mode().Perm() != 0o750 {
		t.Errorf("mode changed to %v", st.Mode().Perm())
	}
	if !exists(filepath.Join(outside, "keep")) {
		t.Error("followed a symlink out of the wiped directory")
	}
}

func TestResetDoesNotCrossMounts(t *testing.T) {
	tmp := filepath.Join(t.TempDir(), "tmp")
	touch(t, filepath.Join(tmp, "stale"))
	touch(t, filepath.Join(tmp, "runners", "other-replica", "work"))
	touch(t, filepath.Join(tmp, "runners", "me", "old"))
	mounts := []string{filepath.Join(tmp, "runners")} // shared bind mount

	// /tmp is wiped; the runner's own work dir on the mount is wiped too.
	if err := resetState("", []string{tmp, filepath.Join(tmp, "runners", "me")}, mounts); err != nil {
		t.Fatal(err)
	}
	if exists(filepath.Join(tmp, "stale")) {
		t.Error("stale file in /tmp survived")
	}
	if !exists(filepath.Join(tmp, "runners", "other-replica", "work")) {
		t.Error("crossed into a mount and wiped another replica's work dir")
	}
	if exists(filepath.Join(tmp, "runners", "me", "old")) || !exists(filepath.Join(tmp, "runners", "me")) {
		t.Error("own work dir on the mount not emptied (or removed)")
	}
}

func TestResetRemovesASymlinkedRootItself(t *testing.T) {
	outside := t.TempDir()
	touch(t, filepath.Join(outside, "keep"))
	work := filepath.Join(t.TempDir(), "r-1")
	if err := os.Symlink(outside, work); err != nil {
		t.Fatal(err)
	}
	if err := resetState("", []string{work}, nil); err != nil {
		t.Fatal(err)
	}
	if exists(work) {
		t.Error("planted symlink kept")
	}
	if !exists(filepath.Join(outside, "keep")) {
		t.Error("followed the planted symlink")
	}
}

func TestResetRemovesRunnerUserEntriesInRunnerDir(t *testing.T) {
	if os.Getuid() != 0 {
		t.Skip("needs root")
	}
	dir := t.TempDir()
	touch(t, filepath.Join(dir, "bin", "Runner.Listener")) // root's: kept
	for _, p := range []string{".runner", "_diag/log", "evil"} {
		touch(t, filepath.Join(dir, p))
	}
	if err := os.Symlink("/tmp", filepath.Join(dir, "bin2")); err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{".runner", "_diag", "_diag/log", "evil", "bin2"} {
		if err := os.Lchown(filepath.Join(dir, p), 1001, 1001); err != nil {
			t.Fatal(err)
		}
	}
	if err := resetState(dir, nil, nil); err != nil {
		t.Fatal(err)
	}
	if !exists(filepath.Join(dir, "bin", "Runner.Listener")) {
		t.Error("removed the root-owned runner")
	}
	for _, p := range []string{".runner", "_diag", "evil", "bin2"} {
		if exists(filepath.Join(dir, p)) {
			t.Errorf("%s (runner user's) survived", p)
		}
	}
}

func TestParseMountinfo(t *testing.T) {
	in := `22 1 0:21 / / rw,relatime - overlay overlay rw
23 22 0:5 / /proc rw - proc proc rw
30 22 8:1 /tmp/runners /tmp/runners rw - ext4 /dev/sda1 rw
31 22 8:1 /x /with\040space rw - ext4 /dev/sda1 rw
`
	got := strings.Join(parseMountinfo(in), ",")
	if got != "/,/proc,/tmp/runners,/with space" {
		t.Errorf("mounts = %s", got)
	}
}
