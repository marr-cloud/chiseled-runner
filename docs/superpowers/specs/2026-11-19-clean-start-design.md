# Every start begins clean

## Problem
With `restart: unless-stopped` (compose.yaml's default) an ephemeral runner
restarts the same container, writable layer included. A job can leave state
for the next one, which may belong to another repository: a modified
`bin/Runner.Listener` that captures the next registration token, a poisoned
`~/.bashrc` or `~/.gitconfig`, a fake tool in `/opt/hostedtoolcache`.

## Approaches
- A (chosen): make the runner's code immutable to uid 1001 and have ghr, as
  root, wipe what 1001 can write on every start. No copy of the runner, no
  extra disk.
- A' (copy): keep a read-only copy and restore `/actions-runner` from it on
  every start. Rejected: ~200 MB written per start and per replica for what
  ownership already gives.
- B (refuse reused containers): rejected, breaks Compose `--scale` with
  `restart`.
- C (document only): rejected, cross-repo persistence by default.

## Design
- Image: `/actions-runner/bin` and `externals` owned by root, not writable by
  others; `/actions-runner` itself root:root mode 1777 (sticky), verified: the
  runner registers and listens; uid 1001 cannot rename `bin`, write
  `bin/Runner.Listener` or delete `externals`.
- ghr at start, only when it runs as root and drops to 1001:
  - `/actions-runner`: remove every top-level entry not owned by root.
  - Empty `/home/runner`, `/tmp`, `/var/tmp`, `/_work`, `/opt/hostedtoolcache`
    and the runner's own work directory; keep the directories (owner 1001
    where they were 1001's, 1777 for /tmp and /var/tmp).
  - Never follow symlinks (`os.RemoveAll` on entries, `Lstat` first) and never
    cross into another mount (per `/proc/self/mountinfo`): a shared bind mount
    such as `/tmp/runners` is left alone except the runner's own work dir.
- Self-update: always `--disableupdate` in this mode (the runner cannot
  replace `bin/`). `DISABLE_AUTO_UPDATE=false` logs a warning and is ignored.
- Non-root start or `RUN_AS_ROOT=true`: no wipe (as today), warning already
  logged.

## Consequences (accepted by the user)
- No runner self-update; images are rebuilt weekly, `docker compose pull`.
- The tool cache does not survive between jobs.

## Verification
Root Go tests: entries owned by 1001 removed, root-owned kept; symlink planted
in a wiped dir points outside and the target survives; a mount inside /tmp is
not emptied; own workdir emptied. Real job pair in one container: job 1 plants
a trojan file, `~/.bashrc`, a tool-cache entry and a file in `/_work`; job 2
(after restart) finds none of them. Startup overhead measured.
