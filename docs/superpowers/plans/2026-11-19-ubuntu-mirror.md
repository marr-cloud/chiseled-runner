# Ubuntu mirror — Implementation Plan
> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans.
**Spec:** `docs/superpowers/specs/2026-11-19-ubuntu-mirror-design.md`

### Task 1: Dockerfile + CI
- [ ] RED: build rootfs stage with `UBUNTU_MIRROR=http://127.0.0.1:9/ubuntu/`; today it ignores the arg (fetches archive.ubuntu.com).
- [ ] Implement chisel source patch (guarded) and apt sources rewrite.
- [ ] GREEN: unreachable mirror → error mentions `127.0.0.1:9`; Azure mirror → full smoke suite passes; `status.d` versions equal to a default build's.
- [ ] build.yml: pass the Azure mirror to both build steps; actionlint. Commit.
### Task 2: docs, PR, review, merge
- [ ] Building-and-extending: `UBUNTU_MIRROR`; Security: integrity unchanged. PR, CI, review, merge.
