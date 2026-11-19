# Docker jobs

For workflows that run `docker build`, container actions or service containers, use the `-docker` image with the host's Docker socket:

```bash
export DOCKER_GID=$(stat -c %g /var/run/docker.sock)
docker compose -f compose.yaml -f compose.docker.yaml up -d --scale runner=4
```

The override does four things:

1. Uses the `-docker` image, which adds the static `docker` CLI.
2. Adds the socket's group to the container (`group_add`). The runner and its jobs stay uid 1001 and keep that group.
3. Mounts the socket.
4. Mounts `/tmp/runners` at the **same path** inside and outside the container and points `RUNNER_WORKDIR_ROOT` at it. Docker resolves bind-mount paths on the host, so a job that does `-v $GITHUB_WORKSPACE:/work` only works if the path means the same thing on both sides. Each replica uses `/tmp/runners/<runner name>`.

Docker creates `/tmp/runners` if it is missing. `ghr` starts as root, creates each runner's subdirectory and gives it to uid 1001, so no preparation is needed.

> **The Docker socket is root on the host.** Anything that can run a job can take over the machine. Use it only for repositories you trust, on dedicated hosts. For untrusted code, use rootless Docker or a Docker-in-Docker sidecar per runner instead.

Docker Desktop (macOS/Windows) exposes the socket as `root:root` with mode `660` inside its VM, so use `DOCKER_GID=0`. Check with `docker run --rm -v /var/run/docker.sock:/s busybox stat -c %g /s`.
