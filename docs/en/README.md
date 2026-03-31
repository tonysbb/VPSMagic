# English Docs Overview

Find the documentation you need by task.

## Getting Started

| Document | For whom |
|----------|----------|
| [Quick Start](./quickstart.md) | First-time users — complete your first backup and restore from scratch |
| [Configuration](./configuration.md) | Setting up cloud remotes, module toggles, dual-remote mode |

## Backup & Recovery

| Document | Description |
|----------|-------------|
| [Backup](./backup.md) | Backup scope, output files, retention policy |
| [Restore](./restore.md) | Local / remote / cross-host restore workflows |
| [Migration](./migrate.md) | Online migration to a new VPS — prerequisites and steps |

## Operations

| Document | Description |
|----------|-------------|
| [Status](./status.md) | `status` and `doctor` command output fields |
| [Scheduled Backups](./schedule.md) | Cron setup, Telegram notifications, log viewing |
| [Troubleshooting](./troubleshooting.md) | Layered troubleshooting for common issues |

## Reference

| Document | Description |
|----------|-------------|
| [Capability Matrix](./capability-matrix.md) | A / B / C recovery grades per module |
| [Workload Profiles](./workload-profiles-and-suitability.md) | Choose your recovery path by VPS workload type |
| [Disclaimer](./disclaimer.md) | Engineering boundaries and usage assumptions |
| [Real Empty-Host Restore Acceptance](./real-empty-host-remote-restore-acceptance.md) | Validated empty-host restore chain |
| [Final Acceptance Summary](./final-acceptance-summary.md) | Current version maturity summary |

## Suggested Reading Order

1. [Quick Start](./quickstart.md) — Complete your first backup and restore
2. [Configuration](./configuration.md) — Set up cloud remotes
3. [Restore](./restore.md) — Master different restore methods
4. [Scheduled Backups](./schedule.md) — Set up automated backups
5. [Troubleshooting](./troubleshooting.md) — When things go wrong

Use `vpsmagic doctor` to quickly understand your VPS workload profile and get restore recommendations.
