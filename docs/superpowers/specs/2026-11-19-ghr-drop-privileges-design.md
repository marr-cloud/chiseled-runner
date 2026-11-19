# Keep runner credentials out of reach of jobs

## Problem (verified on meitrix8208/chiseled-runner:noble)
Jobs run as uid 1001, and so did everything else in the container. A job step
could read `ACCESS_TOKEN` / `APP_PRIVATE_KEY` from `/proc/1/environ`
(docker-init) and `/proc/<ghr>/environ`: scrubbing the runner's environment
does not touch the environment those processes were started with.

## Approaches
- A (chosen): the container starts as root; ghr reads the credentials and runs
  every Runner.Listener invocation (and `ghr -- CMD`) as uid/gid 1001.
  Processes of another uid cannot read root's `/proc/<pid>/environ`. Standard
  pattern (gosu/su-exec), no extra moving parts.
- B: stay non-root; drop docker-init, make ghr PID 1, non-dumpable, and reap
  orphans itself. Rejected: more of our own code for what A gets from the
  kernel's uid check.

## Design
- Dockerfile: no `USER`; files keep 1001 ownership.
- ghr started as root: children get `Credential{Uid: 1001, Gid: 1001, Groups:
  ghr's supplementary groups without 0}` (keeps `--group-add` / `group_add`
  for the Docker socket). The work directory is created and chowned to 1001.
- `RUN_AS_ROOT=true` (upstream's name): children stay root and get
  `RUNNER_ALLOW_RUNASROOT=1`; documented as exposing the credentials to jobs.
- ghr started as non-root (`user: 1001` override): works as before and logs a
  warning that jobs can read the credentials.
- `--dry-run` reports `runner_user=1001` / `root` / `<uid> (no drop)`.

## Non-goals
`.credentials` of the runner itself (readable by uid 1001 by design of every
self-hosted runner); the CI e2e changes (PR #8).
