# Real end-to-end job in CI

## Intent
Smoke tests never talk to GitHub, and they missed real breakage (no
`git submodule`, unwritable `/actions-runner`). Before publishing, each
freshly built image must register as a runner, take a real job and pass it.
Side benefit: startup numbers measured on Linux, not Docker Desktop.

## Goals / non-goals / anti-goals
- Goal: all 4 variants (noble/resolute x slim/docker), on PRs from this repo,
  pushes to main, the weekly schedule and manual runs; publishing is gated on it.
- Goal: report seconds to "Listening for Jobs" and to "Running job" in the
  step summary.
- Non-goal: e2e on fork PRs (no secrets; correct for a public repo with
  self-hosted runners). Non-goal: arm64 e2e (amd64 runners only).
- Anti-goal: a build failure leaving a job queued for a runner that never
  comes; a runner left registered in the repo.

## Approaches
- A (chosen): an `e2e` matrix job in `build.yml` with
  `runs-on: [self-hosted, ghr-e2e-<run_id>-<attempt>-<release>-<target>]`,
  queued from the start; the `image` job starts the runner after the smoke
  tests and waits for it. Tests itself in its own PR.
- B: separate workflow started with `workflow_dispatch`: rejected, the PR that
  adds it cannot test itself and it needs `actions: write` for dispatch.

## Design
- Credentials: a GitHub App installed only on marr-cloud/chiseled-runner,
  repository permission Administration: read and write. Secrets `E2E_APP_ID`,
  `E2E_APP_PRIVATE_KEY`. ghr already supports App auth for repo scope.
- `image` job, step "e2e runner" (after smoke tests, before login/publish):
  `docker run -d --init` the image with APP_ID/APP_PRIVATE_KEY, REPO_URL,
  LABELS=<label>, EPHEMERAL=true, DISABLE_AUTO_UPDATE=true,
  RUNNER_NAME=e2e-<release>-<target>; for `docker` variants also the host
  socket, its gid and `RUNNER_WORKDIR_ROOT` bind-mounted at the same path.
  `timeout 900 docker wait`; pass only if exit 0 and the log has
  `completed with result: Succeeded`; always `docker stop` (deregisters) and
  print the log.
- `e2e` job steps: checkout v7 (pinned), checkout v4 (node20 action),
  `hashFiles`, setup-node (tool cache write), `git submodule` via checkout,
  `test -z "$APP_PRIVATE_KEY"` (secret scrubbing); on docker variants
  `docker run --rm hello-world` and a bind mount of `$GITHUB_WORKSPACE`.
- Orphans: if `image` fails or is cancelled before its runner takes the job,
  a final `if: failure() || cancelled()` step cancels the workflow run
  (needs `actions: write` on that job only).
- Skips: both jobs run only when the event is not a fork PR; the e2e step also
  skips if `E2E_APP_ID` is empty, so the repo works before the App exists.
- Known limit: "Re-run failed jobs" on `image` alone would wait for an e2e job
  that is not re-run (timeout after 15 min); use "Re-run all jobs". Documented.
