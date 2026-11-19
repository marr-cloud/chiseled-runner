# syntax=docker/dockerfile:1.7
#
# GitHub Actions runner on chiselled Ubuntu.
#
#   docker build --build-arg UBUNTU_RELEASE=noble    --target slim   .
#   docker build --build-arg UBUNTU_RELEASE=resolute --target docker .
#
# Targets:  slim    runner + shell + git/curl/jq/tar/xz/awk... (default)
#           docker  slim + the static docker CLI, for jobs that use the host's socket.
#           build   slim + a C toolchain (gcc, binutils, libc headers, make).
#           full    plain Ubuntu with apt: the same runner and ghr, the docker
#                   CLI, build-essential... for jobs chisel cannot serve.
#
# slim, docker and build are built FROM scratch from a rootfs cut with chisel
# (https://github.com/canonical/chisel): no apt, no dpkg, no package manager.

ARG UBUNTU_RELEASE=noble
# GO_IMAGE and DOCKER_CLI_IMAGE take any image reference; by default they name
# the pinned stages below.
ARG GO_IMAGE=go-base
ARG DOCKER_CLI_IMAGE=docker-cli-base

# ------------------------------------------------------- base images ------
# Pinned by digest, so the publish job rebuilds from exactly the bases the
# tested build used. Dependabot (docker ecosystem) bumps tag and digest.
FROM --platform=$BUILDPLATFORM golang:1.25-bookworm@sha256:3b4a11519ad929d1e1d261a12cff056f0c85b735253d7d861346b9c6f8b36437 AS go-base
FROM --platform=$BUILDPLATFORM ubuntu:noble@sha256:73b999393d07f2bf65a40373778a44dc9a6d54ad7718d29247d8ff9413c4d6a8 AS ubuntu-noble
FROM --platform=$BUILDPLATFORM ubuntu:resolute@sha256:d66b366dac61b575bee2aef07e9c26e8070096fbe84a3d4d3eb0da069b5d76db AS ubuntu-resolute
# The same images for the target platform: the base of the `full` target.
FROM ubuntu:noble@sha256:73b999393d07f2bf65a40373778a44dc9a6d54ad7718d29247d8ff9413c4d6a8 AS ubuntu-noble-target
FROM ubuntu:resolute@sha256:d66b366dac61b575bee2aef07e9c26e8070096fbe84a3d4d3eb0da069b5d76db AS ubuntu-resolute-target
FROM docker:29-cli@sha256:34507eb5069d8be82c95dd3b6987d4250fd5fee49b82e2509b7d7a7030740d6d AS docker-cli-base

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
# http only: apt runs before ca-certificates is installed, and the signatures,
# not TLS, are what protect the packages. No credentials (they would end up
# in the published provenance), no characters that need quoting.
printf '%s' "${UBUNTU_MIRROR}" | grep -Eqx 'http://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~%+-]+)*/' || {
  echo "UBUNTU_MIRROR must look like http://host[:port]/path/ (got '${UBUNTU_MIRROR}')" >&2
  exit 1
}
go mod download "github.com/canonical/chisel@${CHISEL_VERSION}"
rm -rf /src
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
FROM ubuntu-${UBUNTU_RELEASE} AS rootfs
ARG UBUNTU_RELEASE
ARG TARGETARCH
ARG UBUNTU_MIRROR=http://archive.ubuntu.com/ubuntu/
# Anything that identifies the archive's current state (CI: a hash of the
# suites' InRelease dates). Nothing reads it, but every RUN below depends on
# it: when Ubuntu publishes updates the build cache stops reusing an old cut
# and apt index, and while the archive is unchanged it still does.
ARG UBUNTU_ARCHIVE_STATE=
# The Ubuntu archive occasionally times out from CI; retry rather than fail
# a weekly build. apt uses the same mirror as chisel; security.ubuntu.com
# and ports.ubuntu.com (noble on an arm64 build host) stay as they are.
# If the sources name archive.ubuntu.com at all, the rewrite must take: a base
# image that changes their format fails here instead of silently going back
# to archive.ubuntu.com.
RUN src=/etc/apt/sources.list.d/ubuntu.sources \
 && if grep -q 'archive\.ubuntu\.com' "$src"; then \
      sed -i "s|http://archive.ubuntu.com/ubuntu/\?|${UBUNTU_MIRROR}|" "$src" \
      && grep -qF "URIs: ${UBUNTU_MIRROR}" "$src" \
      || { echo "could not point $src at ${UBUNTU_MIRROR}; update the rewrite" >&2; exit 1; }; \
    fi \
 && echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80retries \
 && apt-get update -qq \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends ca-certificates jq zstd >/dev/null
COPY --from=chisel /out/chisel /usr/local/bin/chisel
# Building for another architecture (arm64 on an amd64 host): give apt that
# architecture's package lists too, so pkgdb looks packages up as
# name:arch=version. Without them, an arch-specific name (the arm64 build's
# gcc-13-aarch64-linux-gnu) matches the host's cross-compiler package of the
# same name, and scanners get the wrong Source.
RUN <<'EOF'
set -eu
native=$(dpkg --print-architecture)
[ "${TARGETARCH}" != "${native}" ] || exit 0
. /etc/os-release
src=/etc/apt/sources.list.d/ubuntu.sources
sed -i "/^Types:/a Architectures: ${native}" "${src}"
case "${TARGETARCH}" in
  arm64) uris=http://ports.ubuntu.com/ubuntu-ports/ security=${uris} ;;
  amd64) uris=${UBUNTU_MIRROR} security=http://security.ubuntu.com/ubuntu/ ;;
  *) echo "unsupported TARGETARCH ${TARGETARCH}" >&2; exit 1 ;;
esac
cat >> "${src}" <<SRC

Types: deb
Architectures: ${TARGETARCH}
URIs: ${uris}
Suites: ${VERSION_CODENAME} ${VERSION_CODENAME}-updates
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
Architectures: ${TARGETARCH}
URIs: ${security}
Suites: ${VERSION_CODENAME}-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
SRC
dpkg --add-architecture "${TARGETARCH}"
apt-get update -qq
EOF

# cut ROOT RELEASE SLICE_FILE...: chisel cut the slices listed in the files
# (one per line, # comments) into a fresh ROOT, retrying on archive timeouts.
# RELEASE is a chisel-releases branch name or a local directory.
COPY --chmod=755 <<'EOF' /usr/local/bin/cut
#!/bin/sh
set -eu
root=$1 release=$2; shift 2
slices=$(cat "$@" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$')
for attempt in 1 2 3 4; do
  rm -rf "${root}" && mkdir "${root}"
  # shellcheck disable=SC2086 # one argument per slice
  chisel cut --release "${release}" --arch "${TARGETARCH}" --root "${root}" ${slices} && exit 0
  [ "${attempt}" -lt 4 ] || exit 1
  echo "chisel cut failed (attempt ${attempt}); retrying in $((attempt * 15))s" >&2
  sleep $((attempt * 15))
done
EOF

# pkgdb ROOT: scanners (trivy, grype, syft) do not read chisel's manifest.
# Describe each package of ROOT's manifest in ROOT/var/lib/dpkg/status.d/, the
# format distroless images use. The Source field maps binary packages to
# Ubuntu security notices.
COPY --chmod=755 <<'EOF' /usr/local/bin/pkgdb
#!/bin/sh
set -eu
root=$1
mkdir -p "${root}/var/lib/dpkg/status.d"
zstd -dc "${root}/var/lib/chisel/manifest.wall" \
  | jq -r 'select(.kind == "package") | "\(.name) \(.version) \(.arch)"' \
  | while read -r name version arch; do
      # name:arch=version first (see the foreign-architecture setup above);
      # the unversioned fallback (the archive moved on since the cut) only
      # for the build host's own architecture or arch-independent packages.
      show() { apt-cache show "$1" 2>/dev/null | sed -n 's/^Source: //p' | head -1; }
      src=$(show "${name}:${arch}=${version}")
      if [ -z "${src}" ] && { [ "${arch}" = all ] || [ "${arch}" = "$(dpkg --print-architecture)" ]; }; then
        src=$(show "${name}=${version}")
        [ -n "${src}" ] || src=$(show "${name}")
      fi
      {
        echo "Package: ${name}"
        echo "Status: install ok installed"
        [ -z "${src}" ] || echo "Source: ${src}"
        echo "Version: ${version}"
        echo "Architecture: ${arch}"
      } > "${root}/var/lib/dpkg/status.d/${name}"
    done
test -n "$(ls "${root}/var/lib/dpkg/status.d")"
EOF

COPY --chmod=755 <<'EOF' /usr/local/bin/ubuntu-release
#!/bin/sh
case "${UBUNTU_RELEASE}" in
  noble)    echo ubuntu-24.04 ;;
  resolute) echo ubuntu-26.04 ;;
  *) echo "UBUNTU_RELEASE must be noble or resolute" >&2; exit 1 ;;
esac
EOF

COPY slices/${UBUNTU_RELEASE}.txt /slices.txt
RUN <<'EOF'
set -eu
release=$(ubuntu-release)
cut /rootfs "${release}" /slices.txt

# `git submodule` is a shell script that no chisel slice ships, and
# actions/checkout runs it on every checkout. Take it and the two shell
# libraries it sources from the release's signed git package (they are
# architecture-independent).
cd /tmp && apt-get download -qq git && dpkg-deb -x git_*.deb /tmp/git
for f in git-submodule git-sh-setup git-sh-i18n; do
  cp -a "/tmp/git/usr/lib/git-core/$f" /rootfs/usr/lib/git-core/
done

pkgdb /rootfs

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

# ---------------------------------------------------------- toolchain ------
# The `build` target's C toolchain, cut on its own and copied over the slim
# image. Cut from a local copy of chisel-releases so that 24.04, which has
# no make slice, gets one: the same definition 26.04 ships.
FROM rootfs AS toolchain
ARG UBUNTU_RELEASE
ARG TARGETARCH
COPY slices/${UBUNTU_RELEASE}-build.txt /slices-build.txt
RUN <<'EOF'
set -eu
release=$(ubuntu-release)
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends git >/dev/null
git clone -q --depth 1 -b "${release}" https://github.com/canonical/chisel-releases /release
if [ ! -e /release/slices/make.yaml ]; then
  cat > /release/slices/make.yaml <<'YAML'
package: make

essential:
  - make_copyright

slices:
  bins:
    essential:
      - libc6_libs
    contents:
      /usr/bin/make:

  copyright:
    contents:
      /usr/share/doc/make/copyright:
YAML
fi
# gcc's slices ship its LTO plugin but not lto-wrapper, so gcc passes the
# linker an empty -plugin-opt=; ld.bfd ignores it, rust-lld (Rust's default
# linker) fails. Ship lto-wrapper next to the plugin, for the same arch.
# Skipped where the slice already lists it (fixed upstream).
for f in /release/slices/gcc-*-x86-64-linux-gnu.yaml /release/slices/gcc-*-aarch64-linux-gnu.yaml; do
  grep -q 'lto-wrapper:' "$f" && continue
  awk '
    /^      \/usr\/libexec\/gcc\/[^\/]+\/[0-9]+\/liblto_plugin\.so:$/ {
      w = $0; sub(/liblto_plugin\.so:$/, "lto-wrapper:", w)
      print; getline; print; print w; print; next
    }
    { print }' "$f" > "$f.new" && mv "$f.new" "$f"
done
cut /toolchain /release /slices-build.txt
ls /toolchain/usr/libexec/gcc/*/*/lto-wrapper >/dev/null || {
  echo "lto-wrapper missing: update the gcc slice patch" >&2; exit 1; }
pkgdb /toolchain
# Keep /usr and /var (the package records in var/lib/dpkg/status.d, and the
# same empty /var dirs the slim image has): the slim image's /etc, /tmp,
# /lib symlinks and chisel manifest stay as they are. That manifest
# describes the slim cut only; status.d describes both.
find /toolchain -mindepth 1 -maxdepth 1 ! -name usr ! -name var -exec rm -rf {} +
rm -rf /toolchain/var/lib/chisel
find /toolchain -xdev -type f \( -perm -4000 -o -perm -2000 \) -exec chmod ug-s {} +
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
# buildx (docker/build-push-action, `docker build` with BuildKit) and compose,
# where the CLI looks for system-wide plugins. Both are static.
COPY --from=dockercli /usr/local/libexec/docker/cli-plugins/docker-buildx /usr/local/libexec/docker/cli-plugins/docker-compose /usr/local/libexec/docker/cli-plugins/

# -------------------------------------------------------------- build ------
FROM slim AS build
COPY --from=toolchain /toolchain/ /

# --------------------------------------------------------------- full ------
# Plain Ubuntu, for jobs that need apt packages, a C++ compiler, -dev
# libraries... and for images that extend it with `RUN apt-get install`.
# The security model is the slim image's: the container starts as root, ghr
# runs the runner and every job as uid 1001, there is no sudo and no setuid
# binary, and the runner's code is root's and read-only. What it gives up is
# size and a far larger package set to scan and patch (docs/Security.md).
# Runs on the target platform: apt installs under emulation for arm64.
FROM ubuntu-${UBUNTU_RELEASE}-target AS full
ARG UBUNTU_RELEASE
ARG UBUNTU_MIRROR=http://archive.ubuntu.com/ubuntu/
# See the rootfs stage: redo the install when the archive changes.
ARG UBUNTU_ARCHIVE_STATE=
ARG VERSION=dev
ARG RUNNER_VERSION
LABEL org.opencontainers.image.title="chiseled-runner" \
      org.opencontainers.image.description="GitHub Actions self-hosted runner on Ubuntu, with apt (the -full variant of chiseled-runner)" \
      org.opencontainers.image.source="https://github.com/marr-cloud/chiseled-runner" \
      org.opencontainers.image.version="${VERSION}" \
      io.github.actions-runner.version="${RUNNER_VERSION}"
COPY packages/full.txt /tmp/packages.txt
RUN <<'EOF'
set -eu
case "${UBUNTU_RELEASE}" in
  noble)    icu=libicu74 ;;
  resolute) icu=libicu78 ;;
  *) echo "UBUNTU_RELEASE must be noble or resolute" >&2; exit 1 ;;
esac
# UBUNTU_MIRROR for the install only (same guard as the rootfs stage): the
# image keeps Ubuntu's own sources for `apt-get` in images built FROM it.
src=/etc/apt/sources.list.d/ubuntu.sources
cp "${src}" /tmp/ubuntu.sources
if grep -q 'archive\.ubuntu\.com' "${src}"; then
  sed -i "s|http://archive.ubuntu.com/ubuntu/\?|${UBUNTU_MIRROR}|" "${src}"
  grep -qF "URIs: ${UBUNTU_MIRROR}" "${src}" || {
    echo "could not point ${src} at ${UBUNTU_MIRROR}; update the rewrite" >&2; exit 1; }
fi
echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80retries
apt-get update -qq
# shellcheck disable=SC2046 # one argument per package
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
  "${icu}" $(grep -v '^[[:space:]]*#' /tmp/packages.txt | grep -v '^[[:space:]]*$') >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq >/dev/null
mv /tmp/ubuntu.sources "${src}"
# Package lists for those sources, so that `apt-get install` (in a derived
# image, or a job with RUN_AS_ROOT=true) works without an update first.
rm -rf /var/lib/apt/lists/*
apt-get update -qq
apt-get clean
rm -f /tmp/packages.txt

# The runner user (uid and gid 1001, like the slim image) and its directories.
groupadd -g 1001 runner
useradd -u 1001 -g 1001 -m -d /home/runner -s /bin/bash runner
mkdir -p /_work /opt/hostedtoolcache /actions-runner
chown 1001:1001 /_work /opt/hostedtoolcache
chmod 1777 /actions-runner
# No setuid/setgid binaries (su, passwd, mount, ssh-keysign...): a job cannot
# get root back. Packages installed later in a derived image may add some.
find / -xdev -type f \( -perm -4000 -o -perm -2000 \) -exec chmod ug-s {} +
EOF
# A sudo that never raises privileges (full/sudo): `sudo apt-get install`
# in workflows works with RUN_AS_ROOT=true, and explains itself otherwise.
COPY --chmod=755 full/sudo /usr/local/bin/sudo
COPY --from=ghr    /out/ghr /usr/local/bin/ghr
COPY --from=runner /actions-runner /actions-runner
COPY --from=dockercli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=dockercli /usr/local/libexec/docker/cli-plugins/docker-buildx /usr/local/libexec/docker/cli-plugins/docker-compose /usr/local/libexec/docker/cli-plugins/
ENV HOME=/home/runner \
    LANG=C.UTF-8 \
    AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache \
    RUNNER_TOOL_CACHE=/opt/hostedtoolcache
# No USER, as in the slim image.
WORKDIR /actions-runner
ENTRYPOINT ["/usr/local/bin/ghr"]

# The default target is the last stage, so keep `slim` last.
FROM slim
