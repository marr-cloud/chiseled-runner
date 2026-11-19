# syntax=docker/dockerfile:1.7
#
# GitHub Actions runner on chiselled Ubuntu.
#
#   docker build --build-arg UBUNTU_RELEASE=noble    --target slim   .
#   docker build --build-arg UBUNTU_RELEASE=resolute --target docker .
#
# Targets:  slim    runner + shell + git/curl/jq/tar.   (default)
#           docker  slim + the static docker CLI, for jobs that use the host's socket.
#
# The final image is built FROM scratch from a rootfs cut with chisel
# (https://github.com/canonical/chisel): no apt, no dpkg, no package manager.

ARG UBUNTU_RELEASE=noble
ARG GO_IMAGE=golang:1.25-bookworm
ARG DOCKER_CLI_IMAGE=docker:29-cli

# ---------------------------------------------------------------- ghr ------
# The entrypoint. Pure standard library, static, reproducible (-trimpath).
FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS ghr
ARG TARGETOS
ARG TARGETARCH
ARG VERSION=dev
WORKDIR /src
COPY go.mod ./
COPY cmd ./cmd
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" -o /out/ghr ./cmd/ghr

# ------------------------------------------------------------- chisel ------
FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS chisel
ARG CHISEL_VERSION=v1.5.1
# chisel hardcodes the Ubuntu archive URL. Build it from the module proxy's
# source (checked against the Go checksum database) with that one constant
# pointed at UBUNTU_MIRROR. Package integrity is unchanged: chisel verifies
# the archive's signed InRelease against the keys in chisel-releases.
ARG UBUNTU_MIRROR=http://archive.ubuntu.com/ubuntu/
RUN <<'EOF'
set -eu
case "${UBUNTU_MIRROR}" in
  http://*/|https://*/) ;;
  *) echo "UBUNTU_MIRROR must be an http(s) URL ending in /" >&2; exit 1 ;;
esac
go mod download "github.com/canonical/chisel@${CHISEL_VERSION}"
cp -r "$(go env GOMODCACHE)/github.com/canonical/chisel@${CHISEL_VERSION}" /src
chmod -R u+w /src
cd /src
const='const ubuntuURL = "http://archive.ubuntu.com/ubuntu/"'
grep -qF "${const}" internal/archive/archive.go || {
  echo "chisel ${CHISEL_VERSION}: '${const}' not found; update the mirror patch" >&2
  exit 1
}
sed -i "s|${const}|const ubuntuURL = \"${UBUNTU_MIRROR}\"|" internal/archive/archive.go
CGO_ENABLED=0 go build -trimpath -o /out/chisel ./cmd/chisel
EOF

# ------------------------------------------------------------- runner ------
# Download the official runner, verify it, and strip what a Linux glibc
# container never uses (musl/alpine Node builds, npm, node headers...).
FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS runner
ARG TARGETARCH
ARG RUNNER_VERSION
ARG RUNNER_SHA256_AMD64
ARG RUNNER_SHA256_ARM64
# Node versions of the runner's bundle to keep. Node 24 only by default: on
# github.com actions that declare `using: node20` run on Node 24 (required
# since 2026-09-23; the opt-out is gone). "20 24" restores Node 20 (~+100 MB)
# for GitHub Enterprise Server versions that still run them on Node 20.
ARG NODE_VERSIONS="24"
RUN <<'EOF'
set -eu
test -n "${RUNNER_VERSION}" || { echo "RUNNER_VERSION is required" >&2; exit 1; }
# Runners before 2.338.0 use Node 20 internally (hashFiles(), ...).
min=2.338.0
case " ${NODE_VERSIONS} " in *" 20 "*) ;; *)
  [ "$(printf '%s\n%s\n' "${min}" "${RUNNER_VERSION}" | sort -V | head -1)" = "${min}" ] || {
    echo "runner ${RUNNER_VERSION} uses Node 20 internally (before ${min}): build with NODE_VERSIONS=\"20 24\"" >&2
    exit 1; } ;;
esac
case "${TARGETARCH}" in
  amd64) arch=x64;   sha="${RUNNER_SHA256_AMD64}" ;;
  arm64) arch=arm64; sha="${RUNNER_SHA256_ARM64}" ;;
  *) echo "unsupported arch ${TARGETARCH}" >&2; exit 1 ;;
esac
test -n "${sha}" || { echo "RUNNER_SHA256_$(echo "${TARGETARCH}" | tr a-z A-Z) is required" >&2; exit 1; }
curl -fsSL -o /tmp/runner.tgz \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${arch}-${RUNNER_VERSION}.tar.gz"
echo "${sha}  /tmp/runner.tgz" | sha256sum -c -
mkdir /actions-runner
tar -xzf /tmp/runner.tgz -C /actions-runner
cd /actions-runner
# ghr drives bin/Runner.Listener directly, so the bash wrappers go away.
rm -f config.sh run.sh env.sh run-helper.sh.template run-helper.cmd.template safe_sleep.sh \
      bin/installdependencies.sh bin/RunnerService.js \
      bin/libcoreclrtraceptprovider.so
rm -rf externals/*_alpine
for d in externals/node*; do
  v="${d#externals/node}"; keep=""
  for want in ${NODE_VERSIONS}; do [ "$v" = "$want" ] && keep=1; done
  [ -n "$keep" ] || rm -rf "$d"
done
rm -rf externals/node*/lib/node_modules externals/node*/include externals/node*/share \
       externals/node*/bin/npm externals/node*/bin/npx externals/node*/bin/corepack
# The runner's code is root's and read-only to the runner user: a job cannot
# leave a modified Runner.Listener for the next start (see ghr's clean start).
chown -R 0:0 /actions-runner
chmod -R go-w /actions-runner
EOF

# ------------------------------------------------------------- rootfs ------
# Cut the Ubuntu packages we need into /rootfs, add the runner user, and
# record what was installed so image scanners can see it. Runs on the build
# platform: chisel fetches packages for TARGETARCH without emulation.
FROM --platform=$BUILDPLATFORM ubuntu:${UBUNTU_RELEASE} AS rootfs
ARG UBUNTU_RELEASE
ARG TARGETARCH
ARG UBUNTU_MIRROR=http://archive.ubuntu.com/ubuntu/
# The Ubuntu archive occasionally times out from CI; retry rather than fail
# a weekly build. apt uses the same mirror as chisel (security.ubuntu.com,
# and chisel's ports.ubuntu.com for arm64, stay as they are).
RUN sed -i "s|http://archive.ubuntu.com/ubuntu/\?|${UBUNTU_MIRROR}|" /etc/apt/sources.list.d/ubuntu.sources \
 && echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80retries \
 && apt-get update -qq \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends ca-certificates jq zstd >/dev/null
COPY --from=chisel /out/chisel /usr/local/bin/chisel
COPY slices/${UBUNTU_RELEASE}.txt /slices.txt
RUN <<'EOF'
set -eu
case "${UBUNTU_RELEASE}" in
  noble)    release=ubuntu-24.04 ;;
  resolute) release=ubuntu-26.04 ;;
  *) echo "UBUNTU_RELEASE must be noble or resolute" >&2; exit 1 ;;
esac
slices=$(grep -v '^[[:space:]]*#' /slices.txt | grep -v '^[[:space:]]*$')
for attempt in 1 2 3 4; do
  rm -rf /rootfs && mkdir /rootfs
  # shellcheck disable=SC2086 # one argument per slice
  chisel cut --release "${release}" --arch "${TARGETARCH}" --root /rootfs ${slices} && break
  [ "${attempt}" -lt 4 ] || exit 1
  echo "chisel cut failed (attempt ${attempt}); retrying in $((attempt * 15))s" >&2
  sleep $((attempt * 15))
done

# `git submodule` is a shell script that no chisel slice ships, and
# actions/checkout runs it on every checkout. Take it and the two shell
# libraries it sources from the release's signed git package (they are
# architecture-independent).
cd /tmp && apt-get download -qq git && dpkg-deb -x git_*.deb /tmp/git
for f in git-submodule git-sh-setup git-sh-i18n; do
  cp -a "/tmp/git/usr/lib/git-core/$f" /rootfs/usr/lib/git-core/
done

# Scanners (trivy, grype, syft) do not read chisel's manifest. Describe each
# package in /var/lib/dpkg/status.d/, the format distroless images use. The
# Source field maps binary packages to Ubuntu security notices.
mkdir -p /rootfs/var/lib/dpkg/status.d
zstd -dc /rootfs/var/lib/chisel/manifest.wall \
  | jq -r 'select(.kind == "package") | "\(.name) \(.version) \(.arch)"' \
  | while read -r name version arch; do
      src=$(apt-cache show "${name}=${version}" 2>/dev/null | sed -n 's/^Source: //p' | head -1)
      [ -n "${src}" ] || src=$(apt-cache show "${name}" 2>/dev/null | sed -n 's/^Source: //p' | head -1)
      {
        echo "Package: ${name}"
        echo "Status: install ok installed"
        [ -z "${src}" ] || echo "Source: ${src}"
        echo "Version: ${version}"
        echo "Architecture: ${arch}"
      } > "/rootfs/var/lib/dpkg/status.d/${name}"
    done
test -n "$(ls /rootfs/var/lib/dpkg/status.d)"

# /bin/sh -> dash comes from dash_bins. Add the unprivileged runner user.
echo 'runner:x:1001:1001:runner:/home/runner:/bin/bash' >> /rootfs/etc/passwd
echo 'runner:x:1001:'                                   >> /rootfs/etc/group
mkdir -p /rootfs/home/runner /rootfs/_work /rootfs/opt/hostedtoolcache /rootfs/actions-runner
chown 1001:1001 /rootfs/home/runner /rootfs/_work /rootfs/opt/hostedtoolcache
# /actions-runner: the runner writes .runner, .credentials, _diag/ there, but
# must not replace bin/ or externals/ (root's). Sticky and world-writable:
# entries can only be renamed or removed by their owner.
chmod 1777 /rootfs/actions-runner
chmod 1777 /rootfs/tmp
# No setuid/setgid binaries (openssh-client ships ssh-keysign setuid root).
find /rootfs -xdev -type f \( -perm -4000 -o -perm -2000 \) -exec chmod ug-s {} +
EOF

# --------------------------------------------------------------- slim ------
FROM scratch AS slim
ARG VERSION=dev
ARG RUNNER_VERSION
LABEL org.opencontainers.image.title="chiseled-runner" \
      org.opencontainers.image.description="GitHub Actions self-hosted runner on chiselled Ubuntu" \
      org.opencontainers.image.source="https://github.com/marr-cloud/chiseled-runner" \
      org.opencontainers.image.version="${VERSION}" \
      io.github.actions-runner.version="${RUNNER_VERSION}"
COPY --from=rootfs /rootfs/ /
COPY --from=ghr    /out/ghr /usr/local/bin/ghr
COPY --from=runner /actions-runner /actions-runner

ENV PATH=/usr/local/bin:/usr/bin:/bin \
    HOME=/home/runner \
    LANG=C.UTF-8 \
    AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache \
    RUNNER_TOOL_CACHE=/opt/hostedtoolcache

# No USER: the container starts as root so that ghr (and docker-init) keep the
# credentials in root's processes, and ghr runs the runner and every job as
# uid 1001, which cannot read root's /proc/<pid>/environ.
WORKDIR /actions-runner
ENTRYPOINT ["/usr/local/bin/ghr"]

# ------------------------------------------------------------- docker ------
FROM ${DOCKER_CLI_IMAGE} AS dockercli

FROM slim AS docker
COPY --from=dockercli /usr/local/bin/docker /usr/local/bin/docker

# The default target is the last stage, so keep `slim` last.
FROM slim
