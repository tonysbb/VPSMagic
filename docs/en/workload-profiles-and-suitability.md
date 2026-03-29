# Workload Profiles and Suitability

This guide is not based on `VPSA` or any single test machine. It groups servers by **common VPS workload shapes** so a new user can answer:

- what this machine looks like
- which backup / restore path is safer to start with
- which parts are mature today
- which parts still need caution

## First action

Start with:

```bash
bash vpsmagic.sh doctor
```

The `doctor` command reports:

- the current machine profile
- detected workload shape
- dependency and remote readiness
- suggested recovery grades
- a safer adoption path

You can run this before you create any config.

## Common workload profiles

### Profile A: Lightweight general-purpose VPS

Typical traits:

- little or no Docker workload
- a few directories, crontab jobs, reverse proxy configs, or simple services
- you mainly want to capture the current machine state first

Recommended path:

1. Run `vpsmagic init`
2. Choose `Local backups only`
3. Complete one local backup
4. Rehearse one local restore

Best first validation targets:

- local archive creation
- `sha256` verification
- local restore flow

### Profile B: Standard Compose application VPS

Typical traits:

- most services run under Docker Compose
- standard reverse proxy such as Caddy or Nginx
- limited custom paths
- few or no standalone containers

This is the most mature recovery path today.

Recommended path:

1. Start with local backup
2. Rehearse local restore
3. Add remote storage
4. Test cross-host restore later

Main recovery targets for this profile are usually:

- Docker Compose
- reverse proxy
- crontab
- firewall

### Profile C: Compose application with databases

Typical traits:

- Compose is still the main workload shape
- MySQL, PostgreSQL, or SQLite are involved
- recovery quality depends on data state, not only on service startup

Recommended path:

1. Complete a local backup
2. Run a restore rehearsal
3. Verify database state and application data carefully
4. Only then move to remote restore or real cutover

Important boundary:

- database files and dumps can be restored
- this does not automatically guarantee business-level consistency

### Profile D: Systemd service VPS

Typical traits:

- business logic mainly runs from `/etc/systemd/system/*.service`
- Docker may not exist
- common for bots, daemons, or script-driven services

Recommended path:

1. Check how many custom systemd services `doctor` detected
2. Start with local backup
3. After restore, verify which services should start automatically
4. Decide cutover timing carefully for single-instance services

### Profile E: Mixed Docker workload VPS

Typical traits:

- both Compose projects and standalone containers exist
- runtime layout is inconsistent
- custom mounts, external dependencies, and manual edits are common

This is a higher-risk profile.

Recommended path:

1. Do not assume automatic recovery will be complete
2. Treat Compose as the primary recovery target
3. Treat standalone containers as rebuild hints
4. Do a full rehearsal before real cutover

## How to read recovery grades

### Grade A

Automatic recovery support is relatively mature.

Typical examples:

- Docker Compose
- standard reverse proxy
- crontab
- firewall

### Grade B

Recovery is usually possible, but the result still needs manual confirmation.

Typical examples:

- common systemd services
- key user-home configuration
- database dumps and file restoration

### Grade C

The tool should be treated as preserving clues rather than guaranteeing runnable recovery.

Typical examples:

- standalone Docker containers
- remote flows that still depend on missing credentials
- rollback of business-side effects

## When to stop and reassess

If any of these happen, pause instead of adding more automation on top:

1. remote prerequisites are missing
2. `sha256` verification fails
3. restore summary reports errors
4. services start but business behavior is still wrong
5. the workload shape of the machine is still unclear to you

Then go back to:

- [Disclaimer](./disclaimer.md)
- [Restore](./restore.md)

## Practical advice for unfamiliar customer VPSes

For an unfamiliar server, the safest order is:

1. run `vpsmagic doctor`
2. decide which profile the machine matches
3. do one local backup
4. do one local restore rehearsal
5. add remote storage later
6. test cross-host restore only after rehearsal

Do not treat our previous lab machines as the default template.  
The better questions are:

- which profile does this server match
- which modules are currently A / B / C
- which results have already been validated by rehearsal
