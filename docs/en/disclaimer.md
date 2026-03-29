# Disclaimer

This project is an engineering-focused Bash tool for common VPS backup and recovery scenarios. It is not a full system imaging product and it is not a transaction-grade disaster recovery platform.

## Accept these boundaries before use

1. You are willing to rehearse recovery before production cutover.
2. You understand that “successful recovery” means “back to a runnable and maintainable state”, not “every side effect is perfectly reversed”.
3. You are willing to prepare remote prerequisites on the target machine when needed, such as `rclone.conf` or `/root/.oci/config`.
4. You will still verify database state, background jobs, callbacks, queues, and other business-side outcomes yourself.

## What this tool does not promise by default

- Full system-level rollback
- Volume data rollback
- Database business-consistency rollback
- Rollback of side effects in third-party systems
- Identical automatic recovery behavior across every Linux distribution

## Suggested production strategy

1. Take a fresh backup on the source machine.
2. Rehearse a full restore on the target machine.
3. Check the summary, ports, containers, reverse proxy, and business availability.
4. Cut DNS or traffic only after the target side looks correct.
