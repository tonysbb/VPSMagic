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

## Current entry points

- Root overview: [README.md](/Users/terry/Project/Codex/VPSMagicBackup/README.md)
- Chinese user docs: [docs/zh/README.md](/Users/terry/Project/Codex/VPSMagicBackup/docs/zh/README.md)
- Workload profiles: [docs/en/workload-profiles-and-suitability.md](/Users/terry/Project/Codex/VPSMagicBackup/docs/en/workload-profiles-and-suitability.md)

More English task-by-task documentation can be added under `docs/en/` as the user guides are translated.

## Start here

- If you have no remote storage and just want one working backup first:
  - [Quick Start](/Users/terry/Project/Codex/VPSMagicBackup/docs/en/quickstart.md)
- If you want to understand the project boundaries first:
  - [Disclaimer](/Users/terry/Project/Codex/VPSMagicBackup/docs/en/disclaimer.md)
- If you want to configure local-only, single-remote, or dual-remote mode:
  - [Configuration](/Users/terry/Project/Codex/VPSMagicBackup/docs/en/configuration.md)
- If you are preparing to restore on a target machine:
  - [Restore](/Users/terry/Project/Codex/VPSMagicBackup/docs/en/restore.md)

## Suggested reading order

1. [Disclaimer](/Users/terry/Project/Codex/VPSMagicBackup/docs/en/disclaimer.md)
2. [Quick Start](/Users/terry/Project/Codex/VPSMagicBackup/docs/en/quickstart.md)
3. [Configuration](/Users/terry/Project/Codex/VPSMagicBackup/docs/en/configuration.md)
4. [Restore](/Users/terry/Project/Codex/VPSMagicBackup/docs/en/restore.md)
5. [Workload Profiles and Suitability](/Users/terry/Project/Codex/VPSMagicBackup/docs/en/workload-profiles-and-suitability.md)
