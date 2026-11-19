# Configurable Ubuntu mirror for the build

## Problem
chisel hardcodes `http://archive.ubuntu.com/ubuntu/` (internal/archive,
`const ubuntuURL`). On 2026-11-19 that host answered in ~16 s per request for
hours and every CI build of the amd64 rootfs failed, despite 4 retries.

## Approaches
- A (chosen): build arg `UBUNTU_MIRROR` (default unchanged). The chisel stage
  takes chisel's source from the Go module proxy (`go mod download`, checked
  against sum.golang.org), replaces the constant, and builds it; the rootfs
  stage points apt at the same mirror. CI passes the Azure mirror GitHub's own
  runners use. Integrity is unchanged: chisel verifies InRelease's PGP
  signature with the keys in chisel-releases, then every package's digest.
- B: an HTTP proxy/cache in CI. Rejected: more moving parts, same host behind.
- C: keep retrying. Rejected: does not survive a long degradation.

## Design
- `ARG UBUNTU_MIRROR=http://archive.ubuntu.com/ubuntu/` (must end in `/`).
- chisel stage: `go mod download -json github.com/canonical/chisel@$CHISEL_VERSION`,
  copy `Dir`, fail if the expected constant is not found (a chisel upgrade that
  moved it must not silently ignore the mirror), patch, `go build -trimpath`.
- rootfs stage: rewrite `archive.ubuntu.com/ubuntu/` in
  `/etc/apt/sources.list.d/ubuntu.sources` (security.ubuntu.com untouched).
- arm64 (ports.ubuntu.com) unchanged.
- CI: `UBUNTU_MIRROR=http://azure.archive.ubuntu.com/ubuntu/` on every build.

## Verification
Unreachable mirror → chisel error names that URL (proves it is used); Azure
mirror build passes all smoke tests; same package versions recorded as with
the default; default build unchanged.
