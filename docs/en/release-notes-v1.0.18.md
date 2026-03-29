# v1.0.18 Release Notes

Release date: 2026-03-30

## Overview

`v1.0.18` is a small stabilization release focused on real-world usability problems found during source-host backup validation on `NCPDE`.

This version closes the loop on:

- `doctor` looking stalled because early probe phases had no progress output
- `status` hanging on slow or problematic remotes
- banner centering and box deformation in mixed-width terminals
- remote backup counts in `status` diverging from the already-validated restore path

## Key fixes

### 1. `status` remote checks now time out

Remote backup counting in `status` now uses a bounded query instead of an unbounded `rclone lsf` call.

This prevents the whole command from appearing stuck when one remote is slow or unhealthy.

### 2. `status` now reuses restore's remote archive listing rules

The old `status` path maintained its own remote archive filtering logic, which could drift from restore behavior.

`v1.0.18` removes that split:

- `status` now reuses the same remote archive listing helper as `restore`
- text and JSON `status` now report the same backup counts the restore path would actually see

### 3. Better progress visibility in `doctor`

`doctor` now prints lightweight phase messages before workload scanning and dependency/remote evaluation, so a slow probe no longer looks like a silent hang.

### 4. Banner rendering cleanup

Terminal banners are now rendered with width-aware centering instead of fixed-width manual padding.

This fixes:

- titles not being visually centered
- borders being distorted by CJK full-width characters
- inconsistent install completion banners

## Real-world validation

`v1.0.18` was verified on the source host after a fresh remote backup run:

- backup to the `OOS` primary target succeeded
- async replication to `R2` started successfully
- text `status` reported `1` backup on both remotes
- JSON `status` reported `backup_count: 1` and `available: true` for both remotes

## Upgrade guidance

```bash
cd /opt/vpsmagic
git pull --ff-only origin main
bash vpsmagic.sh --version
bash vpsmagic.sh status --config /opt/vpsmagic/config.env
bash vpsmagic.sh status --config /opt/vpsmagic/config.env --format json
```
