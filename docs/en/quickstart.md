# Quick Start

If this is your first time using the tool, start with:

```bash
bash vpsmagic.sh init
```

The current `init` flow supports three modes:

1. `Local backups only`
2. `Local + remote backups`
3. `Generate a config only and refine it later`

For most first-time users, start with `Local backups only`, complete one local backup and one local restore rehearsal, and only then move on to remote storage.

## Shortest successful path

If you want the shortest path with the lowest failure rate:

1. `bash vpsmagic.sh init`
2. Choose `Local backups only`
3. `bash vpsmagic.sh backup --config /opt/vpsmagic/config.env`
4. `bash vpsmagic.sh restore --local /path/to/backup.tar.gz --config /opt/vpsmagic/config.env`

Do not start with remote restore unless you have already completed this basic path.

## Path A: local-only first

Choose this if:

- you do not have cloud storage yet
- you do not have `rclone` yet
- you first want to verify that the tool works on your VPS

## Path B: local + remote

Choose this if:

- you already know you want off-site backups
- you are willing to configure one `rclone` remote first
- you want to store backups on WebDAV, S3-compatible storage, or a drive backend

## Install

```bash
git clone https://github.com/tonysbb/VPSMagic.git /opt/vpsmagic
cd /opt/vpsmagic
bash install.sh
```

## Initialize config

```bash
bash vpsmagic.sh init
```

If you choose:

- `Local backups only`
  - no `rclone` is required first
  - the tool generates `BACKUP_DESTINATION="local"`
- `Local + remote backups`
  - it will guide you through remote type selection
  - then generate the related remote settings

Current remote-type prompts are:

1. `WebDAV / OpenList / AList`
2. `S3-compatible object storage`
3. `Google Drive / OneDrive`
4. `I already have a full rclone target path`

## Run one backup

```bash
bash vpsmagic.sh backup --config /opt/vpsmagic/config.env
```

Then immediately check:

```bash
ls -lh /opt/vpsmagic/backups/archives
sha256sum -c /opt/vpsmagic/backups/archives/*.sha256
```

If this is your first run, stop here and verify the result before moving on to remote recovery.

## Run one restore

```bash
bash vpsmagic.sh restore --local /path/to/backup.tar.gz --config /opt/vpsmagic/config.env
```

Treat this first restore as a rehearsal. At minimum, confirm:

- backup summary shows `Errors: 0`
- both the archive and `.sha256` file exist
- restore summary shows `Errors: 0`
- critical services and ports look reasonable

## Cross-host restore

If your remote paths use `{hostname}`, run on the target machine:

```bash
bash vpsmagic.sh restore \
  --config /opt/vpsmagic/config.env \
  --source-hostname SOURCE_HOSTNAME
```

## When to configure rclone

Recommended order:

1. complete one local backup
2. complete one local restore rehearsal
3. install `rclone`
4. configure remote storage
5. test remote backup and remote restore

If you reverse this order and start with remote restore first, troubleshooting becomes much more expensive.
