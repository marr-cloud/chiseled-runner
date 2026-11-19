# chiseled-runner

Self-hosted **GitHub Actions runner** images on **chiselled Ubuntu**, built to be small, auditable and to scale with plain Docker Compose.

| | |
|---|---|
| Ubuntu releases | `noble` (24.04) and `resolute` (26.04) only |
| Entrypoint | `ghr`, one static Go binary, standard library only, no shell scripts |
| Rootfs | Cut with [chisel](https://github.com/canonical/chisel): no apt, no dpkg, no package manager |
| Scaling | `docker compose up --scale runner=N` works out of the box |
| Architectures | `linux/amd64`, `linux/arm64` |

## Quick start

```bash
git clone https://github.com/marr-cloud/chiseled-runner && cd chiseled-runner
cp .env.example .env        # fill in ORG_NAME (or REPO_URL) and ACCESS_TOKEN
docker compose up -d --scale runner=3
```

Three runners appear in your organisation, named `gh-runner-<container id>`. Scale up or down at any time with another `--scale`; stopping a container deregisters its runner.

Next: [Configuration](Configuration.md) · [Authentication](Authentication.md) · [Scaling](Scaling.md) · [Docker jobs](Docker-jobs.md) · [Security](Security.md)

## Images

| Tag | Contents |
|---|---|
| `noble`, `resolute` | Runner, bash, coreutils, git, curl, jq, tar, gzip, xz, zstd, bzip2, zip/unzip, awk (gawk), diff, patch, less, ssh client, CA certificates, and the libraries `actions/setup-python`'s Python needs (sqlite3, ffi, lzma, bz2, readline, ncurses, gdbm, uuid) |
| `noble-docker`, `resolute-docker` | The above plus the static `docker` CLI with the `buildx` and `compose` plugins, for jobs that use the host's Docker socket |
| `noble-build`, `resolute-build` | `noble` / `resolute` plus a C toolchain: `gcc`/`cc` (13 on noble, 15 on resolute), binutils (`as`, `ld`, `ar`), libc and Linux headers, `make`. Enough to link Rust programs and crates with C code, build cgo and run `go test -race`. No C++ compiler and no `pkg-config` (Ubuntu has no chisel slices for them yet), and no `-flto` or `-static` linking with gcc (its LTO compiler and static libgcc are not in the slices) |
| `<tag>-<runner version>` | Pinned to a runner release, e.g. `noble-2.338.2` |
| `latest` | Same as `noble` |

Published to `docker.io/meitrix8208/chiseled-runner` and `ghcr.io/marr-cloud/chiseled-runner`. Rebuilt every Monday so Ubuntu security updates and new runner releases arrive without any action on your part.

## What is *not* in the image

There is no `apt`, `sudo`, compiler (except on the `-build` tags), Python or Node on `PATH` (Node for JavaScript actions is bundled inside the runner; `actions/setup-python`, `setup-node`, `setup-go`, `setup-java` and `mise` install their toolchains as usual). That is the point of the image. If your workflows need more, see [Building and extending](Building-and-extending.md).
