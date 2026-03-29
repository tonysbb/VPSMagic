# Status

## Standard status view

```bash
bash vpsmagic.sh status --config /opt/vpsmagic/config.env
```

Use this when you want a quick overview of:

- current machine information
- effective configuration
- enabled backup modules
- local backup presence
- remote backup visibility
- scheduled backup status

## Structured output

```bash
bash vpsmagic.sh status --config /opt/vpsmagic/config.env --format json
```

Use this when the output needs to be consumed by:

- shell scripts
- CI jobs
- dashboards
- custom wrappers around the tool

## Current JSON fields

### `command`

Always `status`.

### `format`

Always `json` when `--format json` is used.

### `language`

The effective interface language after CLI and config resolution.

### `system`

Current machine identity and basic runtime information:

- `hostname`
- `operating_system`
- `kernel`
- `primary_ip`

### `configuration`

Effective runtime configuration relevant to backup or restore status:

- `mode`
  - `backup` by default
  - `restore` when `RESTORE_SOURCE_HOSTNAME` is active
- `backup_root`
- `backup_destination`
- `ui_language`
- `remote_targets`
- `primary_target`
- `async_target`
- `restore_source_hostname`
- `interactive_remote_selection`
- `auto_rollback_on_failure`
- `keep_local`
- `keep_remote`
- `encryption_enabled`
- `notifications_enabled`
- `log_file`

### `enabled_modules`

An array of currently enabled backup modules, for example:

- `DOCKER_COMPOSE`
- `SYSTEMD`
- `REVERSE_PROXY`

### `local_backups`

Summary of the local archive directory:

- `archive_dir`
- `backup_count`
- `latest_backup`
- `latest_size_bytes`
- `total_size_bytes`

### `remote_backups`

An array of per-target backup visibility checks.

Each item currently includes:

- `target`
- `backup_count`

If `rclone` is unavailable or no remote target is configured, this array may be empty.

### `schedule`

Current scheduler state:

- `enabled`

## Example interpretation

If:

- `local_backups.backup_count` is `0`
- `remote_backups` is empty
- `schedule.enabled` is `false`

then the machine is configured, but it has not yet reached a stable backup routine.

If:

- `remote_targets` is non-empty
- `primary_target` is empty

that usually means the target list exists, but no explicit primary target is pinned in the config.

## Practical split with `doctor`

Use:

- `doctor --format json` for pre-restore classification and risk assessment
- `status --format json` for current-state inspection
