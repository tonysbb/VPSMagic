# English Docs Overview

This directory is for users who are new to the tool and do not necessarily share the same environment as our own test VPSes.

The important point is:

- your server does **not** need to look like `VPSA`
- but you should not assume every unfamiliar server can be restored the same way

Start by classifying the machine first:

```bash
bash vpsmagic.sh doctor
```

The `doctor` command helps answer:

- what kind of workload this VPS looks like
- which deployment shapes were detected
- whether remote prerequisites are ready
- which parts are closer to A / B / C recovery grades
- which adoption path is safer to start with
- whether anything is currently blocking a real restore

If you want to feed the result into automation, you can also use:

```bash
bash vpsmagic.sh doctor --format json
bash vpsmagic.sh status --format json
```

Use them for slightly different purposes:

- `doctor --format json`: pre-restore classification and risk assessment
- `status --format json`: current machine, configuration, and backup overview

Field reference:

- [Status](./status.md)

## Recommended first path

For a brand-new user, the safest order is:

1. Run `doctor`
2. Start with local-only initialization
3. Run one local backup
4. Rehearse one local restore
5. Add remote storage later
6. Use cross-host restore or migration only after rehearsal

## If you have no rclone and no cloud storage yet

That is fine.  
You can still start using the tool in local-only mode:

```bash
bash vpsmagic.sh init
```

Then choose:

1. `Local backups only`

This gives you a minimal usable path before you deal with remote storage, OCI, R2, or `rclone`.

## Recovery mindset

This project is designed to restore a VPS to a **runnable and maintainable** state, not to promise full system replay for every workload shape.

In practice:

- backup support is wider than restore support
- standard Docker Compose / reverse proxy / common systemd cases are the strongest path
- mixed Docker setups, external credentials, and business-side rollback still need more caution

For remote restore, treat these as intentional security gates rather than optional conveniences:

- `rclone.conf`
- `OCI` credentials when your primary remote depends on them

## Current entry points

- Root overview: [README.md](../../README.md)
- Chinese user docs: [docs/zh/README.md](../zh/README.md)
- Workload profiles: [docs/en/workload-profiles-and-suitability.md](./workload-profiles-and-suitability.md)

More English task-by-task documentation can be added under `docs/en/` as the user guides are translated.

## Start here

- If you have no remote storage and just want one working backup first:
  - [Quick Start](./quickstart.md)
- If you want to understand the project boundaries first:
  - [Disclaimer](./disclaimer.md)
- If you want to configure local-only, single-remote, or dual-remote mode:
  - [Configuration](./configuration.md)
- If you want to understand standard backup behavior:
  - [Backup](./backup.md)
- If you want to inspect the current machine and backup state:
  - [Status](./status.md)
- If you are preparing to restore on a target machine:
  - [Restore](./restore.md)
- If you want the workload suitability view first:
  - [Workload Profiles and Suitability](./workload-profiles-and-suitability.md)
- If you want one validated example of a real empty target host restore:
  - [Real Empty-Host Remote Restore Acceptance](./real-empty-host-remote-restore-acceptance.md)
- If you plan to use migration or scheduled backups:
  - [Migration](./migrate.md)
  - [Scheduled Backups](./schedule.md)
- If you are already in a failure path:
  - [Troubleshooting](./troubleshooting.md)
- If you want the current recovery-grade summary:
  - [Capability Matrix](./capability-matrix.md)
- If you want the high-level acceptance status of the current version:
  - [Final Acceptance Summary](./final-acceptance-summary.md)

## Suggested reading order

1. [Disclaimer](./disclaimer.md)
2. [Quick Start](./quickstart.md)
3. [Configuration](./configuration.md)
4. [Backup](./backup.md)
5. [Status](./status.md)
6. [Restore](./restore.md)
7. [Workload Profiles and Suitability](./workload-profiles-and-suitability.md)
8. [Real Empty-Host Remote Restore Acceptance](./real-empty-host-remote-restore-acceptance.md)
9. [Capability Matrix](./capability-matrix.md)
10. [Final Acceptance Summary](./final-acceptance-summary.md)
