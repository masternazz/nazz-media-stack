# jellyfin-media-stack

One guided installer that deploys a full Jellyfin media stack into a Debian LXC on Proxmox VE.
`README.md` is the source of truth for behaviour — read it before changing installer flow.

## The one rule

This repo is **public**. The installer must stay portable: it detects the current Proxmox host
rather than assuming a storage pool, VLAN, DNS server, NAS address, container ID, or GPU.
Never hardcode homelab-specific values (10.226.x.x, real NAS paths, VLAN tags, CT IDs) into
anything under `install*.sh`, `jellyfin-stack/`, or `scripts/`. That is also why releases are
built from this repo — `scripts/build-release.sh` keeps private values out of the archive.

## Layout

| Path | Purpose |
|---|---|
| `install.sh` | Small remote bootstrap |
| `install-jellyfin-stack.sh` | Proxmox/LXC installer + guided UI |
| `fix-existing-install.sh` / `repair-existing.sh` | Repair paths for a previous/partial install |
| `jellyfin-stack/docker-compose.yml` | Base stack; `.nvidia.yml` / `.amd.yml` are GPU overlays |
| `jellyfin-stack/configure-media-stack.sh` | First-run application wiring |
| `jellyfin-stack/verify-media-stack.sh` | Post-install verification |
| `scripts/build-release.sh` | Builds the hosted release archive + prints the SHA-256 to pin |
| `tests/` | Installer/storage regression checks |

Inside the LXC everything lands at `/opt/mediastack`, config under `/opt/mediastack/config`.

## Testing

Run the shell regression checks from the repo root before shipping installer changes:

```bash
bash tests/test-installer-ui.sh
bash tests/test-storage-mounts.sh
bash tests/test-no-vpn-startup.sh
```

The `.exp` Expect scripts exercise guided dry-run paths when Expect is available.

**Never test installer changes against the production container.** Spin up a disposable CT,
run the full install, verify, then promote. A half-run installer leaves a container in a state
the repair scripts have to guess at.

## Gotchas

- **Recyclarr v8** — the TRaSH baseline must use `config create --template`. The old `include:`
  syntax is dead and silently produces an empty config.
- **GPU transcoding** — check the actual card's codec support before assuming hardware paths.
  A Quadro K2200 does H.264 only, no HEVC encode; the compose overlay will happily start and
  then fall back to CPU under load.
- **Unprivileged LXC GPU passthrough** binds driver libraries by version. A host driver update
  breaks the mounts and needs them re-pinned, then `pct reboot` to re-bind `/dev/nvidia*`.
- Release archives pin a SHA-256 in the public bootstrap — rebuild and re-pin together or the
  bootstrap refuses the download.
