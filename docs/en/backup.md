# Backup

## Standard backup

```bash
bash vpsmagic.sh backup --config /opt/vpsmagic/config.env
```

Current behavior:

1. create a local backup first
2. package the archive
3. generate a `.sha256` file
4. if remote backup is enabled, upload to the primary target synchronously
5. if an async replica target is configured, copy the same backup to the replica target afterwards

## Local-only backup

```bash
bash vpsmagic.sh backup --config /opt/vpsmagic/config.env --dest local
```

Use this when:

- you have no `rclone` yet
- you have no cloud storage yet
- you want the lowest-risk first run

## What a successful backup should leave behind

Under the local archive directory, you should normally see:

- `*.tar.gz`
- `*.tar.gz.sha256`

If remote backup is enabled, the remote target should also contain the same two files.

## What to verify after the first backup

```bash
ls -lh /opt/vpsmagic/backups/archives
sha256sum -c /opt/vpsmagic/backups/archives/*.sha256
```

Do not move on to remote restore until this basic check is clean.
