# Migration

Online migration is for cases where both the source and target VPS are online. It pushes a backup directly from the source to the target over SSH and automatically restores on the target.

## How It Works

```
Source VPS                          Target VPS
  │                                   │
  ├── 1. Check SSH connectivity       ←┤
  ├── 2. Push vpsmagic source & install →┤
  ├── 3. Run local backup              │
  ├── 4. rsync/scp transfer archive   →┤
  ├── 5. Remote verify archive        →┤
  │                                   ├── 6. Auto restore
  │                                   └── 7. Output restore summary
  └── 8. Display migration result + checklist
```

## Prerequisites

| Requirement | Details |
|-------------|---------|
| SSH connectivity | Source must reach target via SSH |
| Root access | Target needs root for restoring services |
| Disk space | Target should have 2× the archive size free |
| rsync (recommended) | Faster transfers; falls back to scp if unavailable |
| Network bandwidth | For large archives, use bandwidth limiting to avoid impacting source services |

The target VPS **does not** need vpsmagic pre-installed — migration handles that automatically.

## Basic Usage

```bash
vpsmagic migrate root@new-vps
```

This single command handles: local backup → transfer → remote install → restore → report results.

## Common Options

```bash
# Specify SSH port
vpsmagic migrate root@new-vps -p 2222

# Limit transfer bandwidth (avoid impacting source services)
vpsmagic migrate root@new-vps --bwlimit 10m

# Specify SSH key
vpsmagic migrate root@new-vps -i ~/.ssh/id_rsa

# Combined options
vpsmagic migrate root@new-vps -p 2222 --bwlimit 10m

# Transfer backup only, don't restore on target
vpsmagic migrate root@new-vps --skip-restore
```

## Full Migration Workflow

### 1. Pre-migration checks

```bash
# Verify source VPS is healthy
vpsmagic status

# Verify SSH connectivity
ssh root@new-vps "echo ok"

# Verify target disk space
ssh root@new-vps "df -h /"
```

### 2. Run migration

```bash
vpsmagic migrate root@new-vps
```

You'll see:
- Backup progress
- Transfer progress
- Remote installation status
- Restore progress and results

### 3. Post-migration verification

On the target machine:

```bash
# Check service status
vpsmagic status

# Check Docker containers
docker ps

# Check reverse proxy
systemctl status caddy  # or nginx

# Check ports
ss -tlnp | grep -E '80|443'
```

### 4. Switch traffic

After confirming the target VPS is working correctly:

1. Update DNS records to point to the target VPS IP
2. Wait for DNS propagation
3. Verify access through the new IP
4. Decommission source VPS services (optional)

## Migration vs Remote Restore

| Comparison | Online Migration | Remote Restore |
|-----------|------------------|----------------|
| Prerequisites | Both machines online, SSH access | Target has cloud access |
| Transfer method | Direct push (rsync/scp) | Pull from cloud storage |
| Requires rclone | No | Yes |
| Best for | Machine swap, instant migration | Disaster recovery, off-site rebuild |
| Single command | ✅ | ✅ |

## Important Notes

- Source services keep running during migration — but operate during off-peak hours when possible
- Large data transfers may saturate bandwidth — use `--bwlimit` to throttle
- Migration does not modify DNS or switch traffic — that's a manual step
- If the target already has services with the same names, a config-level snapshot is created before restore
- After migration, run `vpsmagic init` on the target to set up cloud backups
