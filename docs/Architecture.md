# Architecture

## What `ghr` does

1. Reads its configuration from the environment and validates it. Fails fast with exit code 2 on bad input. Runs as root; everything it starts runs as uid 1001 (see [Authentication](Authentication.md#keeping-secrets-away-from-workflows)).
2. Removes stale registration files left in the container's writable layer by a previous run.
3. Gets a registration token (PAT, or GitHub App JWT then installation token).
4. Runs `bin/Runner.Listener configure --unattended --replace ...`.
5. Runs `bin/Runner.Listener run`, forwarding `SIGTERM`, `SIGINT`, `SIGQUIT` and `SIGHUP` to it.
6. On exit, gets a remove token and runs `bin/Runner.Listener remove`, unless the runner already removed itself (ephemeral runners do).

The container's exit code is the runner's.

## Why not `config.sh` and `run.sh`?

They are bash wrappers that:

- run `ldd` and `ldconfig -NXv | grep libicu` before configuring, which cannot work in an image with no `ldd`, no `ldconfig` and no `ld.so.cache`;
- implement a restart loop in `run-helper.sh`;
- do not forward signals unless `RUNNER_MANUALLY_TRAP_SIG` is set.

`ghr` does the same work in Go, in a few dozen lines, so the image needs none of that machinery.

## Exit codes of the listener

`ghr` handles them like the runner's own `run-helper.sh`:

| Code | Meaning | `ghr` |
|---|---|---|
| 0 | clean stop | exit 0 |
| 1 | fatal error | exit 1 |
| 2 | retryable error | wait 5 s, relaunch |
| 3, 4 | the runner is updating itself | wait up to 30 s for `update.finished`, relaunch |
| 5 | session conflict (same name registered twice) | exit 5 |

A signal received while the listener runs is forwarded and the listener is *not* relaunched.

## Self-update

The runner never updates itself in these images. Its code (`/actions-runner/bin`, `externals`) belongs to root and is read-only to the runner user, so that a job cannot leave a modified runner for the next start; `ghr` therefore always passes `--disableupdate` when it starts as root. Images are rebuilt every week with the latest runner: `docker compose pull && docker compose up -d` updates. GitHub refuses runners that fall too far behind, so do not pin an old image for long.

If `ghr` does not start as root (`user:` override or `RUN_AS_ROOT=true`), the clean start and the read-only code do not apply either, and `DISABLE_AUTO_UPDATE` behaves as usual.

## Image layout

```
/usr/local/bin/ghr          the entrypoint
/actions-runner             the runner (owned by uid 1001)
/_work                      default work root
/opt/hostedtoolcache        tool cache for setup-* actions (emptied on every start)
/usr/bin/{bash,git,curl,..} chiselled Ubuntu packages (see slices/)
/usr/lib/git-core/git-submodule, git-sh-setup, git-sh-i18n
                            from the release's git package: no slice ships
                            them and actions/checkout needs `git submodule`
/var/lib/dpkg/status.d/     one record per package, for scanners (see Security)
/var/lib/chisel/            chisel's manifest
```

The rootfs is assembled in an `ubuntu:<release>` stage on the build platform: chisel downloads and verifies packages for the target architecture, so arm64 images build without emulation.

The runner tarball is 683 MB extracted; the image keeps about 210 MB of it by dropping Node 20 (actions that declare `node20` run on Node 24), the musl/Alpine Node builds, npm and corepack, Node headers, and the shell wrappers.
