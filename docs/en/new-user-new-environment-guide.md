# New User, New Environment Guide

This guide is for a very specific situation:

- you are new to `VPS Magic Backup`
- you are starting from a fresh environment or a not-yet-standardized VPS
- what you need first is the right starting path, not every detail at once

This document is a route selector. It does not replace the detailed task-specific docs.

## First decide which starting path fits you

### Path A: local-only minimum loop first

Use this when:

- you do not have `rclone` yet
- you do not have remote storage ready yet
- you first want to verify that the tool works on the current machine

Goal:

1. produce one local archive
2. complete one local restore rehearsal
3. confirm that summary, checksum, and health checks look reasonable

This is the default recommended path.

### Path B: local + remote from the beginning

Use this when:

- you already know you want off-site backups
- you already have a usable `rclone` remote
- you are willing to run remote preflight before real restore

Goal:

1. create one local archive
2. upload it to a remote target
3. test remote preflight and remote restore

### Path C: cross-host restore / cutover preparation

Use this when:

- you already have a source host
- you already have a target host
- you are moving from “can the tool work?” to “can the workload cut over?”

Goal:

1. run `doctor` on the target host first
2. review blocking items and caution items
3. run remote restore preflight
4. decide whether a real cutover is justified

If you have not completed Path A at least once, do not start with Path C.

## The first step is the same for all paths

Install and initialize:

```bash
git clone https://github.com/tonysbb/VPSMagic.git /opt/vpsmagic
cd /opt/vpsmagic
bash install.sh
bash vpsmagic.sh init
```

Then immediately run:

```bash
bash vpsmagic.sh doctor --config /opt/vpsmagic/config.env
```

`doctor` now gives you:

- current recommendation
- risk level
- blocking items
- caution items

For structured output:

```bash
bash vpsmagic.sh doctor --config /opt/vpsmagic/config.env --format json
```

To inspect the current machine and backup state:

```bash
bash vpsmagic.sh status --config /opt/vpsmagic/config.env
bash vpsmagic.sh status --config /opt/vpsmagic/config.env --format json
```

## Recommended first moves

### If you are on Path A

Follow this order:

1. `init`
2. choose `Local backups only`
3. run one `backup`
4. verify the local archive and `.sha256`
5. run one `restore --local`

Continue with:

- [Quick Start](./quickstart.md)
- [Backup](./backup.md)
- [Restore](./restore.md)

### If you are on Path B

Follow this order:

1. `init`
2. choose `Local + remote backups`
3. configure one remote
4. run one `backup`
5. inspect `status`
6. then run remote restore preflight

Continue with:

- [Quick Start](./quickstart.md)
- [Configuration](./configuration.md)
- [Backup](./backup.md)
- [Status](./status.md)
- [Restore](./restore.md)

### If you are on Path C

Follow this order:

1. run `doctor` on the target host
2. confirm blocking items are empty
3. use `status` to inspect local, remote, and scheduler state
4. if remote paths use `{hostname}`, prepare `--source-hostname`
5. run remote restore preflight
6. only then decide on real restore

Continue with:

- [Restore](./restore.md)
- [Status](./status.md)
- [Troubleshooting](./troubleshooting.md)
- [Real Empty-Host Remote Restore Acceptance](./real-empty-host-remote-restore-acceptance.md)

## Two boundaries you should accept up front

### 1. Credentials are not auto-generated

These are security gates, not convenience features:

- `rclone.conf`
- `/root/.oci/config`

### 2. The first restore should not be treated as production cutover

Do this first:

1. local restore rehearsal
2. remote preflight
3. target-host restore
4. workload validation

Only after that should you cut traffic over.

## If you only want to know which doc to read next

Shortest mapping:

- want one working backup first: [Quick Start](./quickstart.md)
- want to start formal use: [Configuration](./configuration.md)
- want to inspect current machine and backup state: [Status](./status.md)
- want to restore on a target host: [Restore](./restore.md)
- want to understand current maturity and boundaries: [Final Acceptance Summary](./final-acceptance-summary.md)
