# Capability Matrix

If you do not yet know what kind of machine you are dealing with, start with:

```bash
bash vpsmagic.sh doctor
```

Then use this page to interpret the current recovery grades.

## Grade A: mature automatic recovery

- Docker Compose
- reverse proxy
- crontab
- firewall

## Grade B: semi-automatic recovery

- common systemd services
- important user-home configuration
- database dumps and file restoration

## Grade C: manual rebuild or cautious recovery

- standalone Docker containers
- flows that depend on external credentials not yet prepared on the target machine
- rollback of business-side side effects

## Recommended usage

- treat Grade A modules as primary automatic recovery targets
- verify Grade B modules manually after restore
- treat Grade C modules as recovery clues rather than startup guarantees
