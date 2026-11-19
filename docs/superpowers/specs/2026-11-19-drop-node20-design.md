# Drop Node 20 from the default images

## Intent
Faster startup when scaling. On a new host the cost is the image pull, and the
runner layer (~310 MB uncompressed) is the largest and changes with every runner
release. Node 20 is 96 MB of it.

## Why it is safe now
Since 2026-06-16 the runner runs actions that declare `node20` on Node 24, and
since runner 2.338 its internal Node use (`hashFiles()`, ...) is Node 24 as well.
Node 20 is only used when a workflow opts back in with
`ACTIONS_ALLOW_USE_UNSECURE_NODE_VERSION`.

## Goals / non-goals
- Goal: default images ship only Node 24; Node 20 remains a documented build arg.
- Non-goal: removing ICU (~36 MB). Small gain, and invariant globalization would
  leak into job steps that run `dotnet`.
- Non-goal: publishing `-node20` tags (doubles CI for a deprecated runtime).

## Approaches
1. Change the `NODE_VERSIONS` default to `"24"` (chosen).
2. Publish extra `-node20` variants: rejected, see non-goals.

## Design
- Dockerfile: `ARG NODE_VERSIONS="24"`.
- CI smoke test: node24 runs; `externals/node20` is absent.
- Verification: a real job on a local runner using a `node20` action
  (`actions/checkout@v4`) and a `node24` action; compressed size per variant and
  seconds from `docker run` to "Listening for Jobs", before and after.
- Docs: sizes (README, Architecture), how to restore Node 20 (Building), the
  behaviour change (Migrating, Troubleshooting).
