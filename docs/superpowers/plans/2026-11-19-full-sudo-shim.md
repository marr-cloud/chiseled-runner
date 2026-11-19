# `sudo` shim on -full Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On `-full`, a myoung34 workflow's `sudo apt-get install` passes on the first run when `RUN_AS_ROOT=true`. Without it, the job gets a clear message, or a pass when the packages are already in the image.

**Architecture:** The `full` image ships a POSIX sh script at `/usr/local/bin/sudo`, which never raises privileges, together with apt lists matching Ubuntu's own sources. CI smoke tests pin each path of the shim, and the `full` e2e runs as root with a real `sudo apt-get install`.

**Tech Stack:** Dockerfile (BuildKit heredocs), POSIX sh, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-11-19-full-sudo-shim-design.md`

## Global Constraints

- No setuid binary, no real sudo. The shim never raises privileges.
- The chiselled images (`slim`, `docker`, `build`) are unchanged.
- No `APT_PACKAGES` variable.
- The shim's fallback message names both fixes: `RUN_AS_ROOT=true`, or an image built `FROM` `-full` with the packages.

## Review Focus

- `sudo apt-get install -y -q --no-install-recommends a b` as 1001 with a and b installed: options are skipped and only the package names are checked, so it exits 0. If one is missing, it exits 1. (Task 1 smoke test.)
- `sudo -E env` and `sudo -- id -u` as root: they run, and print `0`. (Task 1.)
- `sudo bash -c '...'` as root: it runs, with no option parsing past the command name. (Task 1.)
- Package names with an arch qualifier or version (`hello:amd64`, `hello=2.10-3`): the dpkg check strips `=version` and keeps `:arch`. (Task 1.)
- `sudo apt-get install` with a fresh image and no `update`: the lists exist, so it installs. (Task 2.)

---

### Task 1: The shim

**Files:**
- Create: `full/sudo`
- Modify: `Dockerfile` (`full` stage: `COPY --chmod=755 full/sudo /usr/local/bin/sudo`)
- Modify: `.dockerignore` (`!full/`)
- Modify: `.github/workflows/build.yml` (the `full` smoke-test block)

- [ ] **Step 1: Write the smoke tests in the `full` block of `build.yml`**

  Replace the current "No sudo" check with these:
  - **root** (`--user 0`):
    - `sudo -E -H apt-get install -y -qq hello >/dev/null && hello` prints `Hello, world!`;
    - `sudo -- id -u` prints `0`;
    - `sudo -u root bash -c 'echo ok'` prints `ok`.
  - **1001:**
    - `sudo apt-get install -y hello` exits 1, and stderr contains `RUN_AS_ROOT=true` and `FROM`;
    - `sudo apt-get update` exits 0;
    - `sudo apt-get install -y -q --no-install-recommends curl git:amd64` exits 0 with `already installed`;
    - `sudo id` exits 1;
    - `sudo -u nobody id` exits 1, and so does `sudo -i`;
    - the real binary: `apt-get install hello` without sudo still fails (dpkg lock).
  - The existing "no setuid binaries" check stays.

- [ ] **Step 2: Run it against the current local `cr:noble-full`**

  Extract the smoke step to a script, as before.
  Expected: FAIL at the first shim check (`sudo: command not found`).

- [ ] **Step 3: Implement `full/sudo`**

  - **Options:** loop over the leading arguments:
    - `-E|-H|-n|-k|-S|--preserve-env|--preserve-env=*`: shift;
    - `-u`: the next argument must be `root` or `0`, else refuse;
    - `--`: shift and stop;
    - any other `-*`: refuse;
    - first non-option: stop.
  - **No command left:** usage on stderr, exit 1.
  - **`id -u` = 0:** `exec "$@"`.
  - **Not root:**
    - `apt-get|apt` + `update`: note on stderr, exit 0.
    - `apt-get|apt` + `install`: for each argument not starting with `-`, strip `=*`, then `dpkg-query -W -f='${Status}' "$pkg"`. Every one must equal `install ok installed`; if so, print `already installed: …` and exit 0.
    - **Otherwise:** exit 1 with the message.

- [ ] **Step 4: Rebuild `cr:noble-full` and rerun the smoke script**

  Expected: all lines pass, ending with `Docker Compose version`.

- [ ] **Step 5: Commit**: "Add a sudo shim to the -full images".

### Task 2: apt lists that match the shipped sources

**Files:**
- Modify: `Dockerfile` (`full` stage RUN)
- Modify: `.github/workflows/build.yml` (the "apt ok" check)

- [ ] **Step 1: Change the smoke check**

  Replace `test -z "$(ls /var/lib/apt/lists)"` with `ls /var/lib/apt/lists | grep -Eq '(archive|ports)\.ubuntu\.com'`, and `! ls /var/lib/apt/lists | grep -q azure`.

- [ ] **Step 2: Run it against the Task 1 image.** Expected: FAIL (no lists).

- [ ] **Step 3: Implement**

  After `mv /tmp/ubuntu.sources "${src}"`, run `apt-get update -qq`. Keep `apt-get clean`, and remove only `/tmp/packages.txt`, not the lists.

- [ ] **Step 4: Rebuild and rerun.** Expected: PASS, and the root `sudo apt-get install hello` works without an update.

- [ ] **Step 5: Commit**: "Keep apt lists in -full so install works without update".

### Task 3: e2e as root, and docs

**Files:**
- Modify: `.github/workflows/build.yml` (e2e runner step: add `-e RUN_AS_ROOT=true` when `matrix.target == full`; `e2e` job: step "myoung34-style sudo apt-get install" with `if: matrix.target == 'full'`, running `sudo apt-get install -y hello && hello`)
- Modify: `docs/Migrating-from-myoung34.md`, `docs/Security.md`, `docs/Building-and-extending.md`, `docs/Home.md` (row of `-full`), `README.md`

- [ ] **Step 1: Make the edits**

  - **Migrating:** the `apt`/`sudo` row says "use `-full` with `RUN_AS_ROOT=true`: `sudo apt-get install` works as before, with the same exposure".
  - **Security:** with `RUN_AS_ROOT=true`, jobs can read the credentials and modify the runner. Use `EPHEMERAL=true` and recreate containers.
  - **Building-and-extending:** a subsection, "Stop running jobs as root". It covers a derived image with the packages, unset `RUN_AS_ROOT`, and the fact that workflows keep their `sudo apt-get` lines.

- [ ] **Step 2: Lint the workflow**

  Run `actionlint -no-color -oneline .github/workflows/build.yml`. Expected: no output.

- [ ] **Step 3: Commit, push, open the PR, and watch CI**

  Commit as "Run the -full e2e as root with sudo apt-get; document the way out". Expected: all jobs green, 0 runners left.
