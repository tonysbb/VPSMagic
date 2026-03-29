# Configuration

These are the configuration points that matter most for a normal user.

## Recommended way to configure

Start with:

```bash
bash vpsmagic.sh init
```

The wizard currently supports:

- local-only mode
- local + remote mode
- config-only mode

It only asks about remote storage if you explicitly choose the remote mode.

## What new users should edit first

If you are just starting out, usually you only need to confirm:

- `BACKUP_DESTINATION`
- `BACKUP_ROOT`
- `BACKUP_KEEP_LOCAL`

These more advanced settings can wait:

- `BACKUP_TARGETS`
- `BACKUP_PRIMARY_TARGET`
- `BACKUP_ASYNC_TARGET`
- `RESTORE_SOURCE_HOSTNAME`
- `RESTORE_ROLLBACK_ON_FAILURE`

## Three common configuration levels

### 1. Local-only mode

Best for a first run:

```bash
BACKUP_DESTINATION="local"
BACKUP_TARGETS=""
BACKUP_PRIMARY_TARGET=""
BACKUP_ASYNC_TARGET=""
```

### 2. Single-remote mode

Best when you already have one stable remote:

```bash
BACKUP_DESTINATION="remote"
BACKUP_TARGETS="openlist_webdav:backup/{hostname}"
BACKUP_PRIMARY_TARGET="openlist_webdav:backup/{hostname}"
BACKUP_ASYNC_TARGET=""
```

### 3. Dual-remote mode

Best when you clearly need a primary target plus an async replica:

```bash
BACKUP_DESTINATION="remote"
BACKUP_TARGETS="OOS:bucket/vpsmagic/{hostname},R2:mybucket/vpsmagic/{hostname}"
BACKUP_PRIMARY_TARGET="OOS:bucket/vpsmagic/{hostname}"
BACKUP_ASYNC_TARGET="R2:mybucket/vpsmagic/{hostname}"
```

## Remote targets

```bash
BACKUP_TARGETS="OOS:bucket/vpsmagic/{hostname},R2:mybucket/vpsmagic/{hostname}"
BACKUP_PRIMARY_TARGET="OOS:bucket/vpsmagic/{hostname}"
BACKUP_ASYNC_TARGET="R2:mybucket/vpsmagic/{hostname}"
BACKUP_INTERACTIVE_TARGETS=true
```

Meaning:

- `BACKUP_TARGETS`: candidate remote list
- `BACKUP_PRIMARY_TARGET`: default primary target
- `BACKUP_ASYNC_TARGET`: async replica target
- `BACKUP_INTERACTIVE_TARGETS`: whether backup/restore should list targets interactively

## Remote type mapping in the wizard

The `Local + remote backups` path in `init` currently maps to:

1. `WebDAV / OpenList / AList`
2. `S3-compatible object storage`
3. `Google Drive / OneDrive`
4. `I already have a full rclone target path`

Default examples:

```bash
openlist_webdav:backup/{hostname}
s3:mybucket/vpsmagic/{hostname}
gdrive:VPSMagicBackup/{hostname}
manualremote:backup/{hostname}
```

Notes:

- OCI and R2 belong to the `S3-compatible object storage` category
- advanced users can still enter a full `remote:path` directly

## Selection advice

- If you just want something working first: choose `WebDAV / OpenList / AList`
- If you already use object storage: choose `S3-compatible object storage`
- If you want to avoid object storage complexity: choose `Google Drive / OneDrive`
- If you already know your exact `remote:path`: use manual input

If you do not have a clear remote strategy yet, do not start with dual-remote mode.

## Retention

```bash
BACKUP_KEEP_LOCAL=3
BACKUP_KEEP_REMOTE=30
BACKUP_ROOT="/opt/vpsmagic/backups"
BACKUP_DESTINATION="remote"
```

In local-only mode, the wizard will generate:

```bash
BACKUP_DESTINATION="local"
```

That means:

- no `rclone` is required for the first local backup
- missing OCI / R2 settings will not block local backups

## Restore-related settings

```bash
RESTORE_ROLLBACK_ON_FAILURE=false
# RESTORE_SOURCE_HOSTNAME="NCPDE"
```

- `RESTORE_ROLLBACK_ON_FAILURE`: only controls whether command-line auto rollback is allowed for lightweight config-level rollback
- `RESTORE_SOURCE_HOSTNAME`: used when expanding `{hostname}` during cross-host restore

### When `RESTORE_SOURCE_HOSTNAME` matters

You only need it when:

- your remote paths use `{hostname}`
- you are restoring a source host on another machine

Example:

```bash
bash vpsmagic.sh restore \
  --config /opt/vpsmagic/config.env \
  --source-hostname NCPDE
```

If you do not need cross-host restore yet, you can ignore this setting.
