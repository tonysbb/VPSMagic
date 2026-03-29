# Migration

Online migration is intended for cases where both VPSes are still online.

## Basic usage

```bash
bash vpsmagic.sh migrate root@new-vps
```

## Common examples

```bash
bash vpsmagic.sh migrate root@new-vps -p 2222 --bwlimit 10m
bash vpsmagic.sh migrate root@new-vps --skip-restore
```

## Recommended migration order

1. confirm the source VPS is healthy
2. confirm SSH access to the target VPS
3. run migration
4. verify the restore summary and business path on the target
5. switch DNS or traffic only after validation

## Important mindset

Treat migration as a faster operational path, not as a replacement for rehearsal.

If the target workload shape is unfamiliar, still run:

```bash
bash vpsmagic.sh doctor
```

before treating the result as production-ready.
