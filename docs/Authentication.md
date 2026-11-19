# Authentication

`ghr` asks GitHub for a short-lived *registration token* when a container starts and a *remove token* when it stops. It needs a credential that is allowed to do that. Pick one.

## Personal access token (simplest)

| Scope of the runners | Classic PAT | Fine-grained PAT |
|---|---|---|
| Repository | `repo` | Repository permission **Administration: read and write** |
| Organisation | `admin:org` | Organisation permission **Self-hosted runners: read and write** |
| Enterprise | `manage_runners:enterprise` | not supported |

Use a dedicated machine account, not a personal one.

## GitHub App (recommended for organisations)

Tokens are minted on demand and expire after an hour, nothing long-lived sits in your `.env` except the app's private key.

1. Create an app with **Self-hosted runners: read and write** (organisation permission) for org runners, or **Administration: read and write** (repository permission) for repo runners.
2. Install it on the organisation or repository.
3. Generate a private key and set:

```env
APP_ID=123456
APP_PRIVATE_KEY_FILE=/run/secrets/app_key   # or APP_PRIVATE_KEY with literal \n
```

`APP_ID` may also be the app's Client ID (`Iv1...`). Enterprise runners cannot use a GitHub App; use a PAT.

## Keeping secrets away from workflows

Two things keep the credentials away from job steps:

1. `ghr` removes `ACCESS_TOKEN`, `RUNNER_TOKEN`, `APP_ID`, `APP_LOGIN` and `APP_PRIVATE_KEY` (and their `_FILE` forms) from the environment of the runner process, which job steps inherit. (The upstream image keeps them unless you opt in to `UNSET_CONFIG_VARS`.)
2. The container starts as root and `ghr` runs the runner, and so every job, as uid 1001. The credentials stay in the environment of root's processes (`docker-init`, `ghr`), and another uid cannot read `/proc/<pid>/environ` of those. Without this, a step could `cat /proc/1/environ`.

Both depend on starting the container as root (the image default) with Docker's default capabilities. They do not hold with the `-docker` images and the host's socket: a job can `docker inspect` its own container and read its environment (the socket is root on the host anyway; see [Docker jobs](Docker-jobs.md)). With `user: 1001` or `RUN_AS_ROOT=true` jobs can read the credentials, and `ghr` logs a warning.

For `*_FILE` secrets, mount the file readable by root only (for example mode `0400`, owner root); the runner user then cannot read it.
