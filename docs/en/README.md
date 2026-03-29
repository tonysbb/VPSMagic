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
- Workload profiles: [docs/zh/业务画像与适用场景.md](/Users/terry/Project/Codex/VPSMagicBackup/docs/zh/业务画像与适用场景.md)

More English task-by-task documentation can be added under `docs/en/` as the user guides are translated.
