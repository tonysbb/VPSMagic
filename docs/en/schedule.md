# Scheduled Backups

## Install the schedule

```bash
bash vpsmagic.sh schedule install --config /opt/vpsmagic/config.env
```

## Check schedule status

```bash
bash vpsmagic.sh schedule status --config /opt/vpsmagic/config.env
```

## Remove the schedule

```bash
bash vpsmagic.sh schedule remove --config /opt/vpsmagic/config.env
```

## Recommendations

- complete at least one successful backup and one restore rehearsal before enabling automation
- configure notifications so failures are visible
- do not start with unattended remote restore as your first validation path
