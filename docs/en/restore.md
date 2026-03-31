# Restore

## Two restore paths

### Path A: Local restore (recommended for first-time users)

Best when:

- you already have the `.tar.gz` archive
- the target machine does not yet have remote credentials
- you do not want to deal with `rclone` / `OCI` / `R2` first

```bash
vpsmagic restore --local /path/to/backup.tar.gz
```

### Path B: Remote restore

Best when:

- the target machine already has the required remote prerequisites (at least `rclone.conf`)
- you want to pull the latest backup directly from cloud storage
- you want less manual file transfer during cross-host recovery

```bash
vpsmagic restore
```

Remote access prerequisites (treat these as security gates, not optional conveniences):

- `rclone.conf` configured
- `/root/.oci/config` ready (if the remote path depends on OCI)

## Run `doctor` before restore

```bash
vpsmagic doctor
```

Focus on these 4 fields:

| Field | Meaning |
|-------|---------|
| `Current recommendation` | Final recommended action |
| `Risk level` | Low / Medium / High |
| `Blocking items` | Must resolve first; do not proceed with restore (e.g. missing rclone, missing OCI credentials) |
| `Caution items` | Not immediately blocking, but expect more manual verification afterward (e.g. Systemd, databases) |

## Restore workflow

### Remote restore flow (7 steps)

```
1. Find available backups (local first → enter 0 to switch to remote)
2. Download backup file (rclone copy)
3. SHA256 verification
4. Decrypt (if encryption is enabled)
5. Extract archive
6. Confirm restore scope (requires exact "yes" input)
7. Execute restore by module order + health checks
```

### Local restore flow (5 steps)

```
1. SHA256 verification
2. Decrypt (if encryption is enabled)
3. Extract archive
4. Confirm restore scope (requires exact "yes" input)
5. Execute restore by module order + health checks
```

## Module execution order

Restore modules execute in a fixed order (infrastructure first, then services that depend on them):

| Order | Module | What it restores |
|-------|--------|-----------------|
| 1 | Crontab | User crontabs, system cron directories, `/etc/crontab` |
| 2 | Custom paths | Restore files and directories by path mapping |
| 3 | Firewall | iptables/ip6tables/UFW/nftables/firewalld/fail2ban (**auto-preserves current SSH ports**) |
| 4 | Docker Compose | Project files, volume data, bind mounts, permission repair, `docker compose up -d` |
| 5 | Standalone Docker | Container metadata (**requires manual recreation**) |
| 6 | Reverse proxy | Nginx/Caddy/Apache configuration, auto-install/start/reload |
| 7 | Database | SQLite auto-restored; MySQL/PostgreSQL **only prints manual import commands** |
| 8 | SSL certificates | Let's Encrypt, acme.sh certificate directories |
| 9 | Systemd services | .service files, working directories, program directories, **auto-rebuilds Python venv + pip install** |
| 10 | User home | dotfiles, rclone.conf, etc. (**auto-skips .ssh/authorized_keys to protect current SSH access**) |

## Auto-install capabilities

When the target machine is missing key dependencies, restore automatically attempts installation:

| Dependency | Installation method |
|-----------|-------------------|
| Docker + Compose | APT package sources → Docker official repository (auto-adds GPG key + apt source) |
| Caddy | APT package sources → Caddy official repository (auto-added) |
| Nginx / Apache | System package manager |
| rclone | Official release zip download → system package manager |
| python3-venv | APT install (for rebuilding Python virtual environments in Systemd services) |

> **Note**: Automatic installation only fully supports Debian/Ubuntu (APT). Other distributions may require manual installation.

## Key safety mechanisms

### SSH preservation after firewall restore

After restoring firewall rules, restore automatically detects the current SSH listening ports and ensures they remain open in iptables/ip6tables/UFW. **Your current SSH connection will not be disrupted by restoring the source machine's firewall rules.**

### Pre-restore configuration snapshot

A lightweight snapshot is automatically created before restore, covering:

- `/etc/caddy`, `/etc/nginx`, `/etc/apache2`
- `/etc/systemd/system`
- `/etc/ufw`, `/etc/cron.d`, cron schedule directories
- Current iptables/ip6tables/nftables rules
- Root user's crontab
- Compose project compose files and .env

Snapshot directory: `/opt/vpsmagic/backups/restore/snapshots/`

### User home protection

When restoring `user_home`, the restore **skips overwriting `.ssh/authorized_keys`** to ensure your current SSH key authentication remains intact.

### Caddy TLS self-healing

After restoring Caddy configuration, if stale TLS state is detected (e.g. JWS validation failure), restore automatically clears the local Caddy TLS cache and restarts the service, waiting for certificate re-issuance.

## Health checks (run automatically after restore)

The following checks run automatically after restore completes:

| Check | Pass condition |
|-------|---------------|
| Docker Compose services | Running service count = expected service count |
| Compose ports | All published ports are listening |
| Compose outbound network | Container HTTPS probe to cloudflare.com succeeds |
| Systemd services | `systemctl is-active` returns `active` |
| Reverse proxy | caddy/nginx/apache2 active or listening on 80/443 |
| Proxy ports | 80, 443 are listening |
| rclone availability | Number of usable remotes |

## Single-instance service protection

The following services are **not started automatically** after restore (to avoid conflicts between old and new machines):

- Services marked `START_POLICY=manual` in `status.env`
- Services that clearly match Telegram-bot-related signals

Start these services manually after DNS cutover:

```bash
systemctl start <service-name>
```

## Post-restore checklist

1. Summary shows `Errors: 0`
2. Docker Compose: container counts correct, key ports listening, outbound ok
3. Reverse proxy: caddy/nginx active, 80/443 listening
4. Single-instance services: confirmed "restored but not auto-started" as expected
5. Databases: MySQL/PostgreSQL need manual SQL file import
6. DNS: A records point to the new IP
7. SSL: certificates have been issued

> If the website is down after restore, check in layers: services → reverse proxy → ports → certificates → DNS

## Unattended restore

```bash
vpsmagic restore --auto-confirm --rollback-on-failure
```

- `--auto-confirm`: skip all interactive confirmations
- `--rollback-on-failure`: automatically run lightweight rollback when a critical restore step fails
- Rollback scope: **configuration-level only**; does not roll back volume data, database outcomes, or business-side side effects
