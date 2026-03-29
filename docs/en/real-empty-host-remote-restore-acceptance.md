# Real Empty-Host Remote Restore Acceptance

## Goal

This acceptance pass simulates a genuinely empty target host instead of reusing a partially prepared lab environment.

The purpose is to confirm that the following chain now works:

1. a new user can generate remote-restore configuration through `init`
2. `doctor` can provide configuration-aware guidance in the selected UI language
3. `restore` can clearly report missing remote prerequisites
4. when `OCI` is unavailable, the flow can fall back to another configured remote
5. on a Debian empty host, if `docker-compose-plugin` is missing from the default repositories, the tool can continue by trying Docker's official repository
6. the final restore result passes health checks with `Warnings: 0` and `Errors: 0`

## Test Environment

- source host: `NCPDE`
- target host: `WAWHK`
- backup source: remote object storage
- config path: `/opt/vpsmagic/config.env`
- restore command:

```bash
bash vpsmagic.sh restore --config /opt/vpsmagic/config.env --source-hostname NCPDE
```

## Verified in This Acceptance Pass

- `init` can generate a remote-restore configuration
- `doctor --config` reads `UI_LANG`
- `restore` goes straight into remote restore preflight when remote configuration is already present
- missing `/root/.oci/config` is reported explicitly
- `R2` can continue as the ready fallback remote
- a matching local archive is reused directly when its checksum matches the remote copy
- a configuration-level snapshot is created before restore
- if Debian default repositories do not provide `docker-compose-plugin`, the tool now tries Docker's official repository
- `downloader`, `pdfmaker`, `caddy`, and `downnow-bot` all restored successfully in this pass
- final summary:
  - `Warnings: 0`
  - `Errors: 0`

## Boundaries Confirmed in This Pass

### 1. `rclone.conf` is a security gate

The tool does not generate remote access configuration automatically.

This is intentional, not an omission:

- the operator should explicitly know which remotes the target host may access
- the operator should explicitly know which `rclone remote` is being trusted
- the operator should decide whether remote access should be granted to the target host at all

So before remote restore, the target host must still be prepared with:

- `/root/.config/rclone/rclone.conf`

### 2. `OCI` credentials are also a security gate

For an `OCI` primary target, the tool does not generate or copy:

- `/root/.oci/config`
- the matching private key material

This is also an intentional security boundary.

If the target host does not have OCI credentials:

- the tool reports that explicitly
- it can fall back to another configured remote when one is available
- if prerequisites still cannot be met, `restore --local` remains the fallback path

### 3. Lightweight rollback is still configuration-scoped only

This acceptance pass does not change that boundary:

- no volume-data rollback
- no database-result rollback
- no business-side effect rollback

## Practical Recommendation for Users

1. use `doctor` first to classify the workload and entry path
2. complete one local backup + local restore rehearsal first
3. add remote restore after that
4. treat `rclone.conf` and `OCI` credentials as pre-cutover security gates
5. before real cutover, complete at least one restore rehearsal on the target host

## Related Documents

- [Restore](/Users/terry/Project/Codex/VPSMagicBackup/docs/en/restore.md)
- [Troubleshooting](/Users/terry/Project/Codex/VPSMagicBackup/docs/en/troubleshooting.md)
- [Disclaimer](/Users/terry/Project/Codex/VPSMagicBackup/docs/en/disclaimer.md)
- [Workload Profiles and Suitability](/Users/terry/Project/Codex/VPSMagicBackup/docs/en/workload-profiles-and-suitability.md)
