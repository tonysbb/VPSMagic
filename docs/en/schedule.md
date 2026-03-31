# Scheduled Backups

Once scheduled, your VPS runs backups automatically on a set schedule.

## Install Schedule

```bash
vpsmagic schedule install
```

This installs a cron job that runs backup daily at 3:00 AM by default.

## Check Status

```bash
vpsmagic schedule status
```

## Remove Schedule

```bash
vpsmagic schedule remove
```

## Custom Schedule

Edit `SCHEDULE_CRON` in `config.env`:

```bash
# Default: daily at 3:00 AM
SCHEDULE_CRON="0 3 * * *"
```

Common examples:

| Cron Expression | Description |
|----------------|-------------|
| `0 3 * * *` | Daily at 3:00 AM |
| `0 */6 * * *` | Every 6 hours |
| `0 3 * * 0` | Weekly on Sunday at 3:00 AM |
| `0 3 1,15 * *` | 1st and 15th of each month at 3:00 AM |
| `30 2 * * *` | Daily at 2:30 AM |

After changing the expression, reinstall:

```bash
vpsmagic schedule remove
vpsmagic schedule install
```

## Telegram Notifications

Configure notifications to be alerted on backup success or failure.

In `config.env`:

```bash
NOTIFY_ENABLED=true
TG_BOT_TOKEN="123456:ABC-DEF..."
TG_CHAT_ID="your Chat ID"
```

How to get these:

1. In Telegram, find **@BotFather** → Create a bot → Get the token
2. In Telegram, find **@userinfobot** → Get your Chat ID

Once configured, you'll receive a Telegram message after each backup (success or failure).

## Log Viewing

Scheduled backup logs are written to `/var/log/vpsmagic_cron.log`:

```bash
# View recent backup logs
tail -100 /var/log/vpsmagic_cron.log

# Watch logs in real-time
tail -f /var/log/vpsmagic_cron.log

# Search for errors
grep -i error /var/log/vpsmagic_cron.log | tail -20
```

## Best Practices

1. **Manual first**: Complete at least one successful `vpsmagic backup` before enabling automation
2. **Enable notifications**: Always set up Telegram alerts so failures don't go unnoticed
3. **Watch disk space**: Scheduled backups produce local archives — check `BACKUP_KEEP_LOCAL`
4. **Regular rehearsals**: Do a restore rehearsal at least monthly to confirm backups are usable

## Troubleshooting

### Schedule not running?

```bash
# Confirm cron service is active
systemctl status cron

# Check if the crontab entry exists
crontab -l | grep vpsmagic

# View cron logs
grep CRON /var/log/syslog | tail -20
```

### Schedule runs, but no notification?

- Verify `NOTIFY_ENABLED=true` in config
- Verify `TG_BOT_TOKEN` and `TG_CHAT_ID` are correct
- Test by sending a message to your bot in Telegram — make sure the bot can respond
