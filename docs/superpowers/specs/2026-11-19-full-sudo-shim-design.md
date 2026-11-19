# `sudo` on the -full images: design

## Intent

Someone migrating from myoung34 has workflows that run `sudo apt-get install ...`. Their job should pass on the first run on `-full`, without editing the workflow. myoung34 runs jobs as root by default, so the migrant already accepted root jobs; `ghr` already has `RUN_AS_ROOT=true` for the same thing. On `-full` today, `sudo` does not exist and the apt lists are removed, so the job still fails.

## Goals

- On `-full` with `RUN_AS_ROOT=true`, `sudo apt-get install -y X` (with or without a prior `apt-get update`) works as it does on myoung34.
- Without `RUN_AS_ROOT`, `sudo <cmd>` fails with a message that names the two fixes: set `RUN_AS_ROOT=true`, or build an image `FROM` `-full` with the packages.
- The way out of root jobs (approach 3) is documented. A job running as uid 1001 on an image that already has the packages runs `sudo apt-get install X` unchanged: the shim sees that X is installed and exits 0.

## Non-goals and anti-goals

- No setuid binary and no real sudo. The shim never raises privileges. Anything that let uid 1001 become root would be the `-sudo` variant this design replaces.
- No change to the chiselled images.
- No `APT_PACKAGES` variable for now. Approach 3 is documented as a derived image.

## Approaches

1. **Chosen: a `sudo` shim on `-full`, plus `RUN_AS_ROOT=true`.** Same exposure as myoung34, only when opted in.
2. **A `-sudo` variant with real NOPASSWD sudo.** Rejected: a job with sudo is root anyway, and this adds a setuid binary, another variant, and a false sense of isolation.
3. **Packages declared by the operator, jobs stay at uid 1001.** Documented as the step after migrating: a derived image, plus the shim's "already installed" path.

## Design

- **`/usr/local/bin/sudo`** in `-full`, a POSIX sh script, root-owned, mode 755.
  - Leading options it accepts and ignores: `-E`, `-H`, `-n`, `-k`, `-S`, `--preserve-env[=...]`, and `-u root` / `-u 0`. `--` ends the options.
  - Anything else is refused with an error: `-u <other>`, `-i`, `-s`, unknown options.
  - With no command left, it prints usage and exits 1.
  - **uid 0:** `exec "$@"`.
  - **uid ≠ 0, command `apt-get install` or `apt install` where every non-option package is already installed** (`dpkg-query -W -f='${Status}'` gives "install ok installed"): print "already installed: …" and exit 0.
  - **uid ≠ 0, `apt-get update` / `apt update`:** exit 0 with a note. That keeps the usual `update && install` line working.
  - **Otherwise:** exit 1 with the message from the goals.
- **apt lists kept in `-full`.** After restoring Ubuntu's sources, run `apt-get update` once more, so the lists match the sources the image ships. Rebuilt weekly anyway.
- **CI**
  - Smoke tests:
    - as root, the shim installs a package;
    - as 1001, `sudo apt-get install` of something missing fails with the message;
    - as 1001, the same for an installed package, and `sudo apt-get update`, both exit 0;
    - `sudo -u nobody` is refused;
    - no setuid binaries.
  - e2e for `full` runs with `RUN_AS_ROOT=true` and a step `sudo apt-get install -y hello && hello`. It keeps the Rust/cgo/race steps.
- **Docs**
  - Migrating: the `apt`/`sudo` row points at `-full` + `RUN_AS_ROOT=true`.
  - Security: the trade-off.
  - Building-and-extending: approach 3, "stop being root".

## Left to the builder

The exact message wording and the shim's option-parsing style. Whether the 1001 non-root path stays covered by the e2e: smoke tests cover it, the e2e moves to root.
