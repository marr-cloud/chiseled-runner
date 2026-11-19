# Clean start Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use `- [ ]`.

**Goal:** A restarted container gives the next job no state from the previous one.
**Architecture:** Immutable runner code (root-owned, sticky top dir) + ghr wiping 1001-writable paths at start.
**Tech Stack:** Go stdlib, Dockerfile.
**Spec:** `docs/superpowers/specs/2026-11-19-clean-start-design.md`

## Global Constraints
- Wiped paths: `/home/runner`, `/tmp`, `/var/tmp`, `/_work`, `/opt/hostedtoolcache`, cfg.Workdir; `/actions-runner` top-level entries with owner != 0.
- Only when `s.cred != nil`. Never follow symlinks, never cross mounts.
- `--disableupdate` forced when `s.cred != nil`.

## Review Focus
- Shared `/tmp/runners` bind mount with several replicas: only the own subdir is emptied. Task 1 mount test + Task 3 compose check.
- `RUNNER_WORKDIR` pointing inside a wiped path or on a mount: emptied once, no error. Task 1.
- A wiped dir that is itself a symlink (planted by a job, e.g. `/home/runner` cannot be replaced since `/home` is root's — check): Task 1.
- First start (fresh container): wipe is a no-op and fast. Task 3 timing.
- `ghr -- CMD` still works after wipe. Task 1.

---
### Task 1: wipe (TDD)
**Files:** new `cmd/ghr/reset.go` (`resetState(roots []string, runnerDir string, keep func(path string) bool, mounts []string) error`, `mountPoints() ([]string, error)` parsing `/proc/self/mountinfo`), `cmd/ghr/reset_test.go`, `cmd/ghr/supervisor.go` (call before makeWorkdir when cred != nil; `--disableupdate` forced).
- [ ] Tests (root-only where ownership matters): 1001-owned entry in runnerDir removed, root-owned kept; contents of a root dir removed, dir kept with its mode/owner; symlink entry to an outside dir removed without touching the target; a path listed as a mount point inside a root is skipped; configure args contain `--disableupdate` when cred != nil even with DisableUpdate=false; mountinfo parser on a fixture (escaped `\040` spaces).
- [ ] Run: fail. Implement. Run root + 1000: pass. Commit.
### Task 2: image ownership
- [ ] Smoke test first: `stat -c '%U %a' /actions-runner` = `root 1777`, `bin` and `externals` owned by root and not writable by others; as uid 1001 `mv /actions-runner/bin /actions-runner/x` fails. RED on current image.
- [ ] Dockerfile: runner stage `chown -R 0:0`, `chmod -R go-w`; rootfs `/actions-runner` root 1777. Build, smoke GREEN. Commit.
### Task 3: real verification
- [ ] Temp workflow with two jobs on one label, one ephemeral container with `--restart` emulated by running ghr twice in the same container (docker start of the stopped container): job 1 plants `/actions-runner/x`, `~/.bashrc` marker, `/opt/hostedtoolcache/evil`, `/_work/<name>/../marker`; job 2 asserts none exist and `bin/Runner.Listener` unchanged (sha256). Startup timing of second start.
- [ ] Compose `--scale 2` with compose.docker.yaml: files in one replica's `/tmp/runners/<name>` survive the other's restart. Remove temp workflow. 0 runners.
### Task 4: docs, PR, review, merge
- [ ] Security (clean start, what is wiped), Configuration (DISABLE_AUTO_UPDATE ignored), Scaling (restart is now clean), Troubleshooting (tool cache not kept; update warning), Architecture. Link check. PR, CI, final review, fixes, merge, verify published image with the Task 3 pair.
