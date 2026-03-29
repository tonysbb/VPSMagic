# Troubleshooting

## First decide which layer is failing

Most restore problems fit into one of these four layers:

1. the backup file is missing or its checksum fails
2. remote access prerequisites are missing
3. restore actions ran, but services did not start correctly
4. services started, but the business path is still unavailable

Compress the problem into one layer first. Troubleshooting becomes much cheaper that way.

## Remote restore preflight failures

Common reasons:

- missing `rclone.conf`
- missing `/root/.oci/config` for OCI-backed flows
- target machine cannot reach the remote backend
- Debian default repositories only provide `docker.io` but not `docker-compose-plugin`

Recommended actions:

1. read the `remote restore preflight` output first
2. if credentials cannot be prepared in time, switch to `restore --local`
3. do not confuse “remote access is unavailable” with “the backup does not exist”

If the issue is `Docker / Compose`:

- when the target host does not have Docker, the restore flow tries to install Docker / Compose automatically first
- on Debian hosts, if the default repositories only provide `docker.io` without `docker-compose-plugin`, the tool now also tries Docker's official repository
- if that still fails, the restore summary includes the installation reason so you can handle it manually

## SHA256 verification failures

Check:

- whether the local archive is intact
- whether the `.sha256` file belongs to the same backup
- whether remote download was interrupted or overwritten

If checksum verification fails, do not continue restore until you understand why.

## Compose services restored but still unreachable

Check in this order:

- are all containers `running`
- are the expected ports listening
- is `Compose outbound network` reported as `ok`
- is the reverse proxy `active`

If the host has network access but containers do not, suspect Docker bridge or firewall first, not mounts or tokens.

## Restore succeeded but the website still does not work

Distinguish these cases:

1. the service never started
2. the service started, but the reverse proxy did not
3. the reverse proxy started, but certificates are not ready yet
4. certificates are fine, but DNS / Cloudflare is still pointing incorrectly

## Cloudflare / Caddy certificate issues

Check:

```bash
journalctl -u caddy -n 100 --no-pager
```

If DNS was just switched, a short-lived `525` is not automatically the final root cause. Confirm whether ACME validation has completed first.
