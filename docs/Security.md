# Security

## Runtime

- The runner and every job run as uid 1001 (`runner`), not root. No `sudo`, no setuid or setgid binaries (CI checks it), and no package manager except on the `-full` tags.
- The container itself starts as root only so that `ghr` and `docker-init` can hold the credentials where uid 1001 cannot read them: `ghr` strips them from the runner's environment and runs the runner as 1001 (see [Authentication](Authentication.md#keeping-secrets-away-from-workflows)). Do not override `user:`.
- `EPHEMERAL=true` gives every job a new registration on a clean filesystem. Every start begins clean: `ghr`, as root, removes what the runner user could write during the previous run (everything in `/home/runner`, `/tmp`, `/var/tmp`, `/_work`, `/opt/hostedtoolcache` and the work directory, and every non-root entry in `/actions-runner`), and the runner's own code is root's and read-only to jobs. A restarted container therefore gives the next job none of the previous job's files. It does not follow symlinks or cross into other mounts: a shared `/tmp/runners` keeps the other replicas' directories, and a volume mounted on one of those paths (`-v /tmp:/tmp`, a shared tool cache) is not emptied, so whatever is in it does persist between jobs. Entries owned by root are kept too: the runner user cannot create them, so they are the image's.
- The `-build` tags add a C compiler and linker. That changes nothing about privileges (jobs are still uid 1001, with no root and no setuid binaries), but it is more code in the image to scan and patch, and a job can build native tools the slim image could only download. Use them only for the jobs that compile.
- The `-full` tags are plain Ubuntu, not chiselled. Privileges are the same (uid 1001, no `sudo`, setuid and setgid bits removed at build time, the runner's code root's and read-only), but they ship apt, dpkg, perl, a C/C++ toolchain and several hundred packages, so a scanner reports far more CVEs and there is much more for an attacker to use. Packages you install in an image built `FROM` them may bring setuid binaries back (`passwd`, a real `sudo`...): remove the bits again if your jobs must not get root. Their `sudo` is a script that never raises privileges: it runs the command only for a job that is already root.
- `RUN_AS_ROOT=true` (meant for `-full`, for workflows that run `sudo apt-get install`) runs jobs as root, as myoung34 does by default. A job can then read the registration credentials from `/proc`, change the runner's code, and undo the clean start. Use it with `EPHEMERAL=true` and a registration token (`RUNNER_TOKEN`) rather than a PAT or App key, and recreate the container for every job instead of restarting it.
- Self-hosted runners should not serve public repositories with untrusted pull requests. Anyone who can open a PR can run code on your runner.
- The CI end-to-end runner of this repository is ephemeral, has a single random label for one run and variant, is skipped for pull requests from forks and Dependabot, and holds only a one-hour registration token; registry credentials stay on a different VM. On the `-docker` variants the job has the host's Docker socket, so it can reach that VM's secrets (the registration token and the GitHub App key used to mint it); see [Building and extending](Building-and-extending.md#end-to-end-check).

## Supply chain

- The runner tarball is verified against a SHA-256 taken from the GitHub release, and the build fails if it does not match.
- Ubuntu packages come from the signed Ubuntu archive through chisel, and `chisel` itself is pinned (`CHISEL_VERSION`) and built from the Go checksum database's verified source. With a custom `UBUNTU_MIRROR`, chisel still checks every package against the archive's `InRelease`, signed with the Ubuntu archive keys that chisel-releases lists: the mirror cannot alter packages, but you trust it to be current (chisel takes the `-security` pocket from it too).
- Every GitHub Action in the workflows is pinned to a full commit SHA (with the version as a comment, which Dependabot keeps up to date), and checkouts do not persist the job token.
- Release builds publish an SBOM and SLSA provenance, and the GHCR image carries a GitHub build attestation:

```bash
gh attestation verify oci://ghcr.io/marr-cloud/chiseled-runner:noble --owner marr-cloud
```

- `ghr` has no third-party dependencies, so `go.mod` has no `require` lines. The whole program is about 900 lines in `cmd/ghr/`. Read it.

## Scanning

Image scanners (trivy, grype, syft) do not read chisel's own manifest, and on a plain chiselled image they report no OS packages, and therefore a misleading "0 vulnerabilities". The build writes `/var/lib/dpkg/status.d/<package>` for every package chisel cut (the format distroless images use), with the `Source` field that maps it to Ubuntu security notices, so:

```bash
trivy image meitrix8208/chiseled-runner:noble
```

reports the ~70 Ubuntu packages and their CVEs, and the SBOM published with release builds lists them too. Chisel's manifest stays in `/var/lib/chisel/` as well.

## Updates

Images are rebuilt weekly. A runner older than GitHub's support window is refused, so keep images fresh: `docker compose pull && docker compose up -d`, or let a tool such as Watchtower or Renovate do it.
