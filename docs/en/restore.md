# Restore

## Decide which restore path you need first

### Path A: local restore

Best when:

- you already have a local `.tar.gz` archive
- the target machine does not yet have remote credentials
- you do not want to deal with `rclone`, OCI, or R2 first

### Path B: remote restore

Best when:

- the target machine already has the required remote prerequisites
- you want to pull the backup directly from remote storage
- you want less manual file transfer during cross-host recovery

For remote restore, treat these as security gates rather than optional conveniences:

- `rclone.conf`
- `/root/.oci/config` when the primary path depends on `OCI`

## Run `doctor` before restore

```bash
bash vpsmagic.sh doctor --config /opt/vpsmagic/config.env
```

The current `doctor` output includes a `Pre-restore risk assessment` section. Focus on these fields:

1. `Current recommendation`
2. `Risk level`
3. `Blocking items`
4. `Caution items`

Use them like this:

- `Blocking items`
  - means you should not start a real restore yet
  - for example: remote restore is configured but `rclone` is missing, or the path depends on `OCI` and `/root/.oci/config` is missing
- `Caution items`
  - means restore may still proceed, but you should expect more manual verification afterward
  - for example: custom `Systemd`, databases, standalone Docker containers
- `Risk level`
  - `Low`: usually acceptable for local rehearsal first
  - `Medium`: proceed carefully and rehearse before real cutover
  - `High`: clear the blockers or high-risk conditions first

## Local restore

```bash
bash vpsmagic.sh restore --local /path/to/backup.tar.gz --config /opt/vpsmagic/config.env
```

If this is your first restore, this should usually be your first choice.

## Remote restore

```bash
bash vpsmagic.sh restore --config /opt/vpsmagic/config.env
```

Use this only after the target machine has the required remote credentials and access.

## Cross-host restore

```bash
bash vpsmagic.sh restore \
  --config /opt/vpsmagic/config.env \
  --source-hostname SOURCE_HOSTNAME
```

## Current restore behavior

- local backups are checked first by default
- if local backups exist, you can enter `0` to switch to remote search
- remote restore runs a prerequisite check before listing remote targets
- only remote targets that currently pass preflight are shown
- restore requires an exact `yes` confirmation before it starts
- a lightweight config-level snapshot is created before restore

## Recommended first restore sequence

Use this order:

1. local restore first
2. verify the summary and health checks
3. remote restore second
4. cross-host restore last

Reason:

- local restore introduces the fewest variables
- remote restore adds credentials, network, and remote-path variables
- cross-host restore adds hostname expansion and target-machine differences

## Pre-restore checklist

1. SSH access to the target machine is healthy
2. the target machine has enough disk space
3. if you use remote restore, the target machine really has the required remote credentials
4. you are clear whether this run is local restore, remote restore, or cross-host restore
5. `doctor` does not report unresolved blocking items for this path

## Post-restore checks

1. summary shows `Errors: 0`
2. if you use Compose:
   - container counts look correct
   - required ports are listening
   - `Compose outbound network` is `ok`
3. if you use a reverse proxy:
   - `caddy` / `nginx` is `active`
   - `80/443` are listening
4. if you have single-instance services:
   - confirm they were restored but intentionally not auto-started when expected

If the script says restore succeeded but the website still does not work, do not jump to “restore failed” immediately. Check in layers:

1. did the service actually start
2. did the reverse proxy start
3. are the ports listening
4. has the certificate been issued yet
5. is DNS / Cloudflare pointing to the right target

## Unattended restore

```bash
bash vpsmagic.sh restore \
  --config /opt/vpsmagic/config.env \
  --auto-confirm \
  --rollback-on-failure
```

Important:

- rollback here means **lightweight config-level rollback**
- it is not full system rollback
- it does not roll back volume data, database outcomes, or business-side side effects
