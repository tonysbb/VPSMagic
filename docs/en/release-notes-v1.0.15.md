# v1.0.15 Release Notes

Release date: 2026-03-30

## Overview

`v1.0.15` closes the loop on remote restore preflight, dependency self-healing, and backend mis-detection, while also formalizing structured outputs and documentation entry points.

This version has been validated in real environments with the following outcomes:

- Source-host remote backup succeeded
- Target-host restore from the `R2` fallback remote succeeded
- Target-host restore from the `OOS` primary remote succeeded
- `doctor --format json` and `status --format json` were parsed successfully on a real machine
- English and Chinese primary-path documentation are both available

## Highlights

### 1. `doctor --format json`

Structured `doctor` output is now available with fields such as:

- `profile`
- `workload`
- `dependencies`
- `risk_assessment`
- `recommended_path`

This makes pre-restore risk assessment consumable by automation, CI, or external tools.

### 2. `status --format json`

Structured `status` output now covers:

- system information
- current configuration
- enabled modules
- local backup overview
- remote backup overview
- scheduler state

## Key Fixes

### 1. Stricter remote restore preflight

Remote preflight now distinguishes between:

- remote not configured
- remote configured but currently unreachable
- primary remote unavailable while a fallback remote is usable

It no longer conflates remote access failures with “backup not found”.

### 2. `rclone` self-healing and backend detection fixes

This version tightens multiple `rclone` paths in restore scenarios:

- restore can auto-install `rclone` when it is missing
- when a required backend is missing, restore first attempts an official release install
- key restore paths now prefer `/usr/local/bin/rclone`
- backend support detection now relies on `rclone config show <remote>`

The last change fixes a real false positive:

- the old logic incorrectly flagged `OOS/oracleobjectstorage` as “backend unsupported”
- the new logic inspects the remote config `type` directly and has been validated on a real target host

### 3. `init` prompt cleanup

- removed the extra blank line after remote-type selection
- Telegram notifications no longer remain enabled when `Bot Token` or `Chat ID` is left empty

### 4. More resilient `status` remote reporting

- text `status` no longer aborts when one remote is unreadable
- JSON `status` now reports `available: true/false` per remote

### 5. Caddy TLS self-heal

Restore can now perform a one-time local TLS-state reset when it detects known stale Caddy state patterns during certificate issuance, including:

- `Unable to validate JWS`
- `caddy_legacy_user_removed`

## Documentation and productization

This version also includes:

- GitHub-friendly relative doc links
- a “new user, new environment” guide
- an English final acceptance summary
- `status --format json` documentation
- reorganized doc entry points
- redacted storage and environment-specific examples in the docs

## Real-world validation summary

`v1.0.15` has completed the following real-world loop:

1. the source host created and uploaded a backup to the primary and fallback remotes
2. the target host initialized a fresh config
3. `doctor` correctly identified workload and risk signals
4. `restore` selected usable remotes based on preflight conditions
5. the target host restored successfully from `R2`
6. the target host restored successfully from `OOS`
7. final health checks and execution summaries completed with `Warnings: 0 / Errors: 0`

## Upgrade guidance

If you are upgrading to `v1.0.15`, start with:

```bash
cd /opt/vpsmagic
git pull --ff-only origin main
bash vpsmagic.sh doctor --config /opt/vpsmagic/config.env
bash vpsmagic.sh status --format json
```

Before running a remote restore on a target host, verify that:

- `rclone config show <remote>` can parse the remote correctly
- `doctor` reports no blocking items
- restore preflight reflects the expected availability of the primary and fallback remotes

## Compatibility

This release does not introduce breaking config-key changes.

Existing `config.env` files remain valid. If you want the updated onboarding and example guidance, refer to [config.example.env](../../config.example.env).
