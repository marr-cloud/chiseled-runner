# Troubleshooting

**`invalid configuration` at start.** `ghr` validates before doing anything; the message names the variable. Try `--dry-run`.

**`HTTP 401/403/404` getting the registration token.** The credential lacks the permission for that scope, or the org/repo name is wrong. See [Authentication](Authentication.md). A 404 on a repo usually means the token cannot see it.

**Runners show up Offline after `docker compose down`.** The container was killed before it could deregister. Keep `stop_grace_period: 2m`. Stale entries can be deleted in GitHub; `--replace` handles re-registration under the same name.

**`RUNNER_NAME` exported in the shell is ignored by Compose.** On purpose: put it in `.env`. GitHub Actions exports its own `RUNNER_NAME` (`GitHub Actions 123...`) to every step, overriding a step's `env:`, so a deploy job running `docker compose up` would otherwise name every runner after itself.

**Two runners with the same name / `Session conflict`.** Do not set `RUNNER_NAME_SUFFIX=none` with more than one replica.

**`docker: permission denied` in a job.** `DOCKER_GID` does not match the socket's group. Check `stat -c %g /var/run/docker.sock`.

**`jobs ... can read the registration credentials` warning.** The container was started as a non-root `user:` or with `RUN_AS_ROOT=true`. See [Authentication](Authentication.md#keeping-secrets-away-from-workflows).

**`create workdir ... permission denied`, container restarting.** Only when the container does not start as root (a `user:` override): the work directory's parent is not writable by that user, usually a bind mount Docker created as root. Remove the override, or run the `install -d` command the log's `hint` gives on the host.

**Container actions fail to mount the workspace.** The work directory must exist at the same path on the host and in the container; see [Docker jobs](Docker-jobs.md).

**A job needs a tool that is not installed.** Add its slice or use a different base; see [Building and extending](Building-and-extending.md).

**Zombie processes accumulate.** Run with `init: true` (set in `compose.yaml`) or `docker run --init`.

**`Node.js 20 is deprecated ... being forced to run on Node.js 24: <action>`.** Expected: that action declares `node20` and runs on Node 24, which is all github.com allows since 2026-09-23. Update the action to silence it.

**`node20/bin/node: no such file or directory` on GitHub Enterprise Server.** Your GHES version still runs `node20` actions on Node 20, and the image ships only Node 24. Build it with `NODE_VERSIONS="20 24"`; see [Building and extending](Building-and-extending.md).

**`ghr runs as root but was denied` / `cannot start the runner ... operation not permitted`.** The container runs with reduced capabilities (`cap_drop: [ALL]`, a restrictive Kubernetes security context). `ghr` needs `CHOWN`, `DAC_OVERRIDE`, `SETUID`, `SETGID` and `KILL` (Docker's defaults include them). On Kubernetes, `runAsNonRoot: true` refuses this image because it starts as root; `runAsUser: 1001` works but lets jobs read the credentials.

**`docker exec` into a runner.** It enters as root now, so files you create under `/actions-runner` or the work directory belong to root. Use `docker exec -u 1001` for anything the runner should own; such a shell also inherits the container's environment, credentials included.

**Every job downloads its tools again.** `setup-node`, `setup-go`, ... cannot reuse the tool cache from a previous job: it is emptied on every start, because a job could otherwise leave a poisoned tool for the next one. Bake tools you always need into a derived image (see [Building and extending](Building-and-extending.md)).

## Known limitations

- On `noble` no Kerberos libraries are included, so Kerberos/NTLM-authenticated proxies are not supported (`resolute` ships them with curl).
- The runner does not update itself (see [Architecture](Architecture.md#self-update)); pull the weekly image instead.
- `git` has no hook templates (`warning: templates not found` on `git init`); harmless.
