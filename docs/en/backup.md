# Backup

## Basic Usage

```bash
vpsmagic backup
```

What happens:

1. Run 10 collectors to scan and capture the current machine state
2. Package everything into a `.tar.gz` archive
3. Generate a `.sha256` checksum file
4. If remote backup is enabled, upload to the primary remote target
5. If an async replica target is configured, copy to the replica target afterwards

## Backup Scope

`vpsmagic backup` automatically scans the following 10 modules:

| Module | What it collects | Config toggle |
|--------|-----------------|---------------|
| Docker Compose | `docker-compose.yml`, `.env`, Dockerfile, named volume data, bind mount dirs, config files (yaml/conf/sh/py/json etc.), directory permission snapshots | `ENABLE_DOCKER_COMPOSE` |
| Standalone Docker | Container config, mount volume info (rebuild clues) | `ENABLE_DOCKER_STANDALONE` |
| Systemd Services | `.service` files, `EnvironmentFile`, Python venv + `pip freeze` | `ENABLE_SYSTEMD` |
| Reverse Proxy | Caddy / Nginx / Apache / Traefik configuration | `ENABLE_REVERSE_PROXY` |
| Database | MySQL / PostgreSQL logical dumps, SQLite file copies | `ENABLE_DATABASE` |
| SSL Certificates | Let's Encrypt / acme.sh certs and account data | `ENABLE_SSL_CERTS` |
| Crontab | All user crontab entries | `ENABLE_CRONTAB` |
| Firewall | UFW / iptables / nftables / firewalld rules | `ENABLE_FIREWALL` |
| User Home | `.bashrc`, `.ssh/authorized_keys`, `.config/rclone`, etc. | `ENABLE_USER_HOME` |
| Custom Paths | Any files/directories specified in `EXTRA_PATHS` | `ENABLE_CUSTOM_PATHS` |

Most modules support `auto` detection. You can also specify targets manually in `config.env`.

## Backup Output

On success, the archive directory (default: `/opt/vpsmagic/backups/archives/`) contains:

```
vpsmagic_<hostname>_<yyyymmdd>_<hhmmss>.tar.gz        # Backup archive
vpsmagic_<hostname>_<yyyymmdd>_<hhmmss>.tar.gz.sha256  # SHA256 checksum
```

Internal archive structure:

```
<backup_name>/
├── manifest.txt        # Backup metadata (hostname, timestamp, OS, VPSMagic version)
├── system_info/        # Installed package lists (dpkg/apt/yum/pip/npm/docker images)
├── docker_compose/     # Compose project files, volume data, bind mounts, directory permissions
├── systemd/            # Systemd service files, working directories, venv info
├── reverse_proxy/      # Reverse proxy configuration
├── database/           # Database exports
├── ssl_certs/          # SSL certificates
├── crontab/            # Crontab entries
├── firewall/           # Firewall rules
├── user_home/          # User home configuration
└── custom_paths/       # Custom paths
```

## Backup Modes

### Local-only backup

```bash
vpsmagic backup --dest local
```

Archive stays on the local machine. Suitable for:
- First-time experience
- No off-site disaster recovery needed
- Manual transfer to target machine later

### Local + remote backup

```bash
vpsmagic backup
```

Requires `BACKUP_DESTINATION="remote"` and remote targets in `config.env`. Creates a local archive first, then uploads to remote.

### Upload only

```bash
vpsmagic upload
```

Does not re-run backup — just uploads the latest local archive to remote. Useful for retrying after a network interruption.

## Retention Policy

| Config | Default | Description |
|--------|---------|-------------|
| `BACKUP_KEEP_LOCAL` | `3` | Keep N most recent local backups |
| `BACKUP_KEEP_REMOTE` | `30` | Keep N most recent remote backups |

Older backups beyond the retention count are cleaned up automatically after each backup.

## Encrypted Backup

Set a password in `config.env` to enable AES-256-CBC encryption:

```bash
BACKUP_ENCRYPTION_KEY="your-strong-password"
```

The same password is required for restore. Encrypted files have a `.tar.gz.enc` extension.

## Dry Run

```bash
vpsmagic backup --dry-run
```

Scan and report only — no packaging or uploading. Useful for verifying configuration.

## Common Issues

### Backup too slow?

- Check if large Docker volumes are being packaged
- Remote upload speed depends on network — use `RCLONE_BW_LIMIT` to throttle and avoid impacting services

### Backup file too large?

- Disable unneeded modules via config toggles
- Use `EXTRA_PATHS` carefully to avoid packaging unnecessary large files

### Remote upload failed?

- Verify rclone config: `rclone lsd your_remote:path`
- Check remote storage space
- See [Troubleshooting](./troubleshooting.md)
