# ghr drops privileges — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use `- [ ]`.

**Goal:** Jobs can no longer read the runner's credentials from `/proc/*/environ`.
**Architecture:** Container starts as root; ghr runs every child as 1001.
**Tech Stack:** Go stdlib (`syscall.Credential`), Dockerfile.
**Spec:** `docs/superpowers/specs/2026-11-19-ghr-drop-privileges-design.md`

## Global Constraints
- Runner uid/gid: 1001/1001 (constants `runnerUID`, `runnerGID`). Group 0 never passed to children.
- Env `RUN_AS_ROOT` (boolean, default false). Go tests run as root and non-root (CI test job is non-root).

## Review Focus
- `group_add` docker gid still reaches the job (Docker variants): covered by Task 3 local job with the socket.
- Non-root start (`user: 1001`) still works: Task 2 Step 4.
- Workdir on a root-owned bind mount (`/tmp/runners` created by Docker): now works, Task 3.
- `ghr -- CMD` runs as 1001 too: Task 1 test.
- Self-update path writes as 1001 into `/actions-runner` (owned 1001): unchanged.

---
### Task 1: credential selection and wiring (TDD)
**Files:** `cmd/ghr/supervisor.go`, `cmd/ghr/config.go`, `cmd/ghr/main.go`, tests in `cmd/ghr/supervisor_test.go`, `cmd/ghr/config_test.go`.
- [ ] Tests first: `TestRunnerCredential` table: (uid 0, groups [0 999], runAsRoot false) → `&syscall.Credential{Uid:1001,Gid:1001,Groups:[]uint32{999}}`; (uid 0, runAsRoot true) → nil; (uid 1001) → nil. `TestChildEnvRunAsRoot`: `RUNNER_ALLOW_RUNASROOT=1` only when children run as root. Config: `RUN_AS_ROOT=true` → `cfg.RunAsRoot`. Root-only test (skip if non-root): supervisor started as root runs fake listener `configure`, `run` and `ghr -- id -u` as 1001 (fake script records `id -u`), workdir owned by 1001.
- [ ] Run: fail (undefined `runnerCredential`, `RunAsRoot`).
- [ ] Implement `runnerCredential(uid int, groups []int, runAsRoot bool) *syscall.Credential`; `Supervisor.cred`; `attach` sets `SysProcAttr.Credential` (merge with Setpgid in `command`); workdir chown when cred != nil; `childEnv(environ, childRoot bool)`; warning log when uid != 0; `describe()` adds `runner_user=`.
- [ ] Run suite as uid 1000 and as root: pass; gofmt; commit.

### Task 2: image runs as root
**Files:** `Dockerfile`, `.github/workflows/build.yml` (smoke).
- [ ] Smoke test first: `docker run --rm "$IMG" --dry-run ...` prints `runner_user=1001`; fails on current image (no field).
- [ ] Remove `USER 1001:1001`; comment why.
- [ ] Build noble slim locally; all smoke checks pass.
- [ ] `docker run --user 1001 ... --dry-run` → `runner_user=1001 (no drop)` and a warning. Commit.

### Task 3: real verification
- [ ] Register a real runner (`ACCESS_TOKEN` from `gh auth token`, label `ghr-leakcheck`, `NO_DEFAULT_LABELS=true`); `docker exec -u 1001` scan of `/proc/*/environ` for `ACCESS_TOKEN=` → none readable. Before the fix (published image) the same scan found pid 1 and ghr.
- [ ] Temporary workflow on this branch, runner with socket + `--group-add` + `/tmp/runners` root-owned bind: job checks `id -u` = 1001, `/proc/*/environ` has no `ACCESS_TOKEN=`, `docker run --rm hello-world` works. Remove workflow. 0 runners left.

### Task 4: docs, PR, merge, publish
- [ ] Security, Authentication, Migrating (`RUN_AS_ROOT`), Docker-jobs (dir no longer needs 1001 ownership? only if Task 3 shows it), Architecture, README "Safer defaults". Link check. Commit.
- [ ] PR, CI green, final review, merge, verify published image with the Task 3 scan.
