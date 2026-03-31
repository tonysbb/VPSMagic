# Quick Start

This guide walks you through a complete **backup → verify → restore** cycle from scratch.

If you already know the basics, use this as a command reference by scenario.

## Prerequisites

- A running VPS (Debian / Ubuntu / CentOS or other mainstream Linux)
- Root access
- About 10 minutes

**Not required yet:** rclone, cloud storage, OCI credentials. These can wait until after your first successful run.

## Step 1: Install

```bash
git clone https://github.com/tonysbb/VPSMagic.git /opt/vpsmagic
cd /opt/vpsmagic
bash install.sh
```

The installer checks base dependencies (bash / curl / tar / gzip) and offers to install rclone, rsync, and Docker.

After installation, you can use the `vpsmagic` command from anywhere.

## Step 2: Initialize Config

```bash
vpsmagic init
```

The wizard asks for your language preference, then your backup mode:

| Option | Description | Recommendation |
|--------|-------------|----------------|
| `1) Local backups only` | Backup to local disk | Good for trying out |
| `2) Local + cloud backups` | Backup to both local and cloud | **Recommended for production** |
| `3) Generate config only` | Create template, edit later | Advanced users |

> 💡 If you already have `rclone` and cloud storage, choose `2` to set it up in one step.

## Step 3: Environment Diagnosis (optional but recommended)

```bash
vpsmagic doctor
```

`doctor` tells you:

- Your VPS workload profile (Compose app / Systemd services / lightweight general purpose…)
- What services were detected for backup
- Whether anything blocks restore
- Risk level and recommendations

If `doctor` reports "blocking items", resolve them before proceeding.

## Step 4: Run Backup

```bash
vpsmagic backup
```

On success, you'll see a summary like:

```
╔══════════════════════════════════╗
║     Backup Summary                ║
╠══════════════════════════════════╣
  Total modules: 8
  Succeeded: 8
  Skipped: 0
  Errors: 0
  Archive: /opt/vpsmagic/backups/archives/vpsmagic_hostname_20260331_030000.tar.gz
```

**How to confirm success:**

- Summary shows `Errors: 0`
- Archive directory contains both `*.tar.gz` and `*.tar.gz.sha256`

If the files are missing, backup didn't complete — don't proceed.

## Step 5: Verify Backup

```bash
ls -lh /opt/vpsmagic/backups/archives/
sha256sum -c /opt/vpsmagic/backups/archives/*.sha256
```

Expected output:

```
vpsmagic_hostname_20260331_030000.tar.gz: OK
```

If it shows `FAILED`, check disk space and archive integrity first.

## Step 6: Restore Rehearsal

> ⚠️ **Don't wait for a failure to try restoring for the first time.** Rehearse on a test environment or target machine first.

### Local restore (you have the archive file)

```bash
vpsmagic restore --local /opt/vpsmagic/backups/archives/vpsmagic_hostname_20260331_030000.tar.gz
```

### Remote restore (target machine has cloud access)

```bash
vpsmagic restore
```

After restore, verify:

1. Summary shows `Errors: 0`
2. Docker Compose containers are all running
3. Reverse proxy (Caddy / Nginx) is active
4. Key ports are listening (80 / 443 etc.)

If the summary looks fine but the site is down, troubleshoot in order: services → reverse proxy → ports → certificates → DNS.

## Command Reference by Scenario

### Backup

```bash
# Full backup (per config.env settings)
vpsmagic backup

# Local-only backup
vpsmagic backup --dest local

# Override remote target for this run
vpsmagic backup --remote myremote:bucket/path

# Dry-run (simulate only)
vpsmagic backup --dry-run
```

### Restore

```bash
# Remote restore (recommended)
vpsmagic restore

# Local archive restore
vpsmagic restore --local /path/to/backup.tar.gz

# Cross-host restore (remote paths contain {hostname})
vpsmagic restore --source-hostname SOURCE_HOSTNAME

# Unattended restore with auto-rollback on failure
vpsmagic restore --auto-confirm --rollback-on-failure
```

### Migration

```bash
# Direct push migration
vpsmagic migrate root@new-vps

# With SSH port and bandwidth limit
vpsmagic migrate root@new-vps -p 2222 --bwlimit 10m

# Transfer only, don't restore on target
vpsmagic migrate root@new-vps --skip-restore
```

### Scheduled Backups

```bash
# Install cron job (default: daily at 3:00 AM)
vpsmagic schedule install

# Check status
vpsmagic schedule status

# Remove cron job
vpsmagic schedule remove
```

### Status & Diagnostics

```bash
# System and backup overview
vpsmagic status

# Environment diagnosis and restore suggestions
vpsmagic doctor

# JSON output (for scripts/CI)
vpsmagic status --format json
vpsmagic doctor --format json
```

## Next Steps

- Configure cloud backup → [Configuration](./configuration.md)
- Understand restore workflows → [Restore](./restore.md)
- Set up scheduled backups → [Scheduled Backups](./schedule.md)
- Something went wrong → [Troubleshooting](./troubleshooting.md)
