# Building and extending

## Build locally

```bash
# find the runner version and its checksums
v=2.338.2
sha_amd64=$(curl -fsSL https://github.com/actions/runner/releases/download/v$v/actions-runner-linux-x64-$v.tar.gz | sha256sum | cut -d' ' -f1)
sha_arm64=$(curl -fsSL https://github.com/actions/runner/releases/download/v$v/actions-runner-linux-arm64-$v.tar.gz | sha256sum | cut -d' ' -f1)

docker buildx build \
  --build-arg UBUNTU_RELEASE=noble \
  --build-arg RUNNER_VERSION=$v \
  --build-arg RUNNER_SHA256_AMD64=$sha_amd64 \
  --build-arg RUNNER_SHA256_ARM64=$sha_arm64 \
  --target slim -t chiseled-runner:noble .
```

`--target docker` adds the Docker CLI. Other build arguments: `NODE_VERSIONS` (`"24"`; `"20 24"` brings Node 20 back, about +100 MB, for GitHub Enterprise Server versions that still run `node20` actions on Node 20, and is required to build runners older than 2.338.0), `CHISEL_VERSION`, `GO_IMAGE`, and `UBUNTU_MIRROR` (default `http://archive.ubuntu.com/ubuntu/`): the Ubuntu archive chisel and the build's apt download from, e.g. `http://azure.archive.ubuntu.com/ubuntu/` (what CI uses) or a local mirror. It must be a plain `http://host[:port]/path/` URL: no `https` (the build's apt runs before CA certificates are installed; the signatures below are what protect the packages) and no credentials (build arguments are recorded in the published provenance). chisel still takes arm64 packages from `ports.ubuntu.com`, but on an arm64 build host the build's own apt for `resolute` uses the mirror, so it needs arm64 there. Packages are checked against the archive's signed `InRelease` either way: a mirror cannot alter them, but a stale one can hold back updates, security updates included.

## Add tools

Tools come from `slices/<release>.txt`, one chisel slice per line. Find slice names in [chisel-releases](https://github.com/canonical/chisel-releases) (`slices/<package>.yaml`) and add them, for example `gawk_bins` or `zip_bins`, then rebuild. One slice per line, comments only on their own lines. If a package has no slice you need, you can contribute one upstream, or copy the files from the release's package in the `rootfs` stage, as the Dockerfile does for `git-submodule`. Packages added as slices show up in `/var/lib/dpkg/status.d/` automatically.

## End-to-end check

Before publishing, CI starts every freshly built amd64 image as an ephemeral runner of this repository and runs a real job on it (the `e2e` job in `build.yml`):

- a JavaScript action that declares `node20`, which must run on Node 24;
- `hashFiles()`, `actions/setup-node` writing to the tool cache, and `git submodule`;
- no runner credentials visible to job steps;
- on `-docker` images: `docker run hello-world` and a bind mount of `$GITHUB_WORKSPACE`.

The runner's only label is `ghr-e2e-<random>-<release>-<variant>`, and the image job passes only if the runner's log shows it ran *that* variant's `e2e` job and the job succeeded. The step summary reports seconds from container start to "Listening for Jobs" and to the job being picked up.

How the credentials are kept apart:

- The GitHub App key never enters the container. The image job mints an installation token, uses it to get a registration token (valid one hour, good only for registering a runner), and passes only that as `RUNNER_TOKEN`. Afterwards it deletes the runner through the API if it is still registered.
- The image job, whose VM runs the job's code, has no registry credentials and only `contents: read`. A separate `publish` job, which needs both `image` and `e2e`, rebuilds from the image job's build cache, pushes and attests.

### Setting it up in a fork or copy

1. Create a GitHub App (no webhook) with the repository permission **Administration: read and write**, and install it only on the repository.
2. Add the secrets `E2E_APP_ID` and `E2E_APP_PRIVATE_KEY` (the `.pem`), and the variable `E2E_ENABLED=true`.

Without `E2E_ENABLED=true` the e2e parts are skipped and the build behaves as before. They are always skipped for pull requests from forks and from Dependabot, which get no secrets.

### When it fails

- **The run ends cancelled, with "no runner will come for: `e2e (...)`".** An image job failed before its runner could take its job (a build or smoke-test failure, or the runner never got online), so the `cancel-orphans` job cancelled the run instead of leaving that job queued. The real error is in the failed `image` job.
- **Re-running.** Use *Re-run all jobs*: it also draws a new label. *Re-run failed jobs* re-runs `image` without its `e2e` job, so the new runner waits for nothing and fails after 15 minutes.

### By hand

To see a real job on a local build, register an ephemeral runner with a unique label against a repository you own and push a workflow with `runs-on: [self-hosted, <label>]`:

```bash
ACCESS_TOKEN=$(gh auth token) docker run --rm --init -e ACCESS_TOKEN \
  -e REPO_URL=https://github.com/OWNER/REPO -e LABELS=my-e2e -e EPHEMERAL=true \
  chiseled-runner:noble
```

It takes one job, then removes itself from the repository.

## When chisel is not enough

If your jobs need `apt`, `sudo`, compilers or Python, a chiselled image is the wrong base. Reuse just the runner and `ghr` on a normal Ubuntu image instead:

```dockerfile
FROM ubuntu:noble
RUN apt-get update && apt-get install -y --no-install-recommends \
      libicu74 libssl3t64 zlib1g ca-certificates git curl jq build-essential sudo \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -u 1001 -m runner
COPY --from=ghcr.io/marr-cloud/chiseled-runner:noble --chown=1001:1001 /actions-runner /actions-runner
COPY --from=ghcr.io/marr-cloud/chiseled-runner:noble /usr/local/bin/ghr /usr/local/bin/ghr
USER runner
WORKDIR /actions-runner
ENTRYPOINT ["/usr/local/bin/ghr"]
```

Use `libicu78` on `resolute`.

## Tests

```bash
go vet ./... && go test -race ./...
```

The tests cover configuration, the GitHub API client (including a real RS256 verification of the App JWT), and the whole lifecycle against a fake `Runner.Listener`: registration, signal forwarding, deregistration, restart codes, secret scrubbing.
