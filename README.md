# Jellyfin Media Stack — one-command Proxmox installer

Deploy a complete, auto-configured Jellyfin media stack into a Debian LXC on a
Proxmox VE host with a single command. It uses an unprivileged LXC normally;
if the host filesystem blocks Proxmox's unprivileged template extraction, the
installer clearly warns and retries in compatible privileged mode. Optional NVIDIA GPU
transcoding, onboard or NFS media storage, and a guided terminal UI are built in.

The installer doesn't just start containers — it **wires the whole stack
together automatically** (download client, indexers, libraries, requests,
subtitles) so a fresh install is usable immediately, regardless of skill level.

## What you get

| Category | Apps |
|----------|------|
| Media server | **Jellyfin** (HW transcode capable) |
| Requests | **Jellyseerr** |
| Automation (*arr) | **Sonarr, Radarr, Lidarr, Prowlarr, Bazarr** |
| Downloads | **qBittorrent** behind **Gluetun** VPN |
| Quality profiles | **Profilarr** (TRaSH Guides GUI) + **Recyclarr** |
| Books / comics | **Kavita, Mylar** |
| Stats & invites | **Jellystat, Wizarr** |
| Management | **Portainer, Homarr**, and a **Media Stack Home** portal |

Everything is reachable from the **Media Stack Home** page at
`http://<LXC-IP>:8088`.

## What gets configured automatically

- Shared admin login applied to Jellyfin, qBittorrent, Profilarr, and Portainer
- qBittorrent categories + save paths, routed through the Gluetun VPN
- Sonarr / Radarr / Lidarr root folders and download clients
- Prowlarr → *arr application sync
- Bazarr connected to Sonarr/Radarr with a safe subtitle-repair timer
- Jellyfin libraries: Movies, TV Shows, Anime, Music, Books
- Jellyseerr initialized against Jellyfin + Sonarr/Radarr
- Profilarr pre-connected to Sonarr/Radarr with the TRaSH Guides database linked
- **TRaSH Guides quality profiles + custom formats applied automatically** via
  Recyclarr — Sonarr **WEB-1080p** and Radarr **HD Bluray + WEB**

> The TRaSH baseline is applied on install via Recyclarr's bundled templates.
> Opt out with `--no-trash-profiles` if you'd rather choose everything yourself.
> Either way, **Profilarr** (`:6868`) gives you the full TRaSH GUI to customize
> or add more profiles afterward. Recyclarr also re-syncs daily to keep formats
> current.

## Requirements

- A **Proxmox VE** host (run the installer on the host, as root)
- Either free **onboard Proxmox storage** or an **NFS export** for media. A
  second NFS export (e.g. a QNAP) is optional.
- Optional: an **NVIDIA** (NVENC/CUDA) or **AMD** (VAAPI) GPU on the host for
  hardware transcoding — auto-detected, NVIDIA preferred when both are present
- A VPN account for Gluetun (defaults assume NordVPN; edit `docker-compose.yml`
  and the `.env` for other providers)

## Quick start

Run this on the Proxmox host as root:

```bash
bash -c "$(curl -fsSL https://cloud.masternazz.com/s/ddfie8QwGyZp9Hi/download)"
```

That bootstrap downloads a SHA-256-pinned bundle, verifies it, and runs the
installer. No authentication needed — this is the recommended path.

<!-- This repository is private. If it is ever made public, rotate or remove the
     hosted link above, since it would become publicly visible here. -->

Or clone and run:

```bash
git clone https://github.com/masternazz/nazz-media-stack.git
cd nazz-media-stack
sudo ./install-jellyfin-stack.sh
```

A GitHub-hosted bootstrap (`install.sh`) is also included, but
`raw.githubusercontent.com` only serves it while this repository is private if
you supply a token that can read it:

```bash
export GITHUB_TOKEN=...
bash -c "$(curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  https://raw.githubusercontent.com/masternazz/nazz-media-stack/main/install.sh)"
```

Running with no flags launches the Proxmox-style terminal installer. It has a
branded header and the familiar settings menu:

- **Default Settings** uses detected Proxmox storage/timezone, untagged DHCP,
  automatic GPU selection, and the standard resource allocation. It asks
  whether media should use a managed onboard disk or an NFS/NAS export, then
  collects only the settings required for that choice and the stack credentials.
- **Default Settings (verbose)** uses the same answers and shows command output.
- **Advanced Settings** walks through container, template, resource, network,
  storage, GPU, and application options.

Normal installs hide noisy package output behind animated status messages and
green completion checks. Full output remains in a protected
`/tmp/jellyfin-media-stack-*.log` file, and `--verbose` exposes it live. The
installer reattaches to the controlling terminal when the bootstrap was piped
into Bash, so whiptail is not silently skipped. If no terminal is available,
it stops safely and requires an explicit `--no-gui` unattended run.

Onboard mode creates a separate Proxmox-managed LXC volume and mounts it at
`/mnt/nas`, so every application uses the same paths as an NFS installation.
The guided installer selects the active storage pool with the most available
space and lets you change both the pool and volume size before installation.
Destroying/replacing that LXC also destroys its managed onboard media volume;
the installer displays this warning before replacing an existing container.

Some Proxmox hosts have ACLs disabled (`noacl`) on storage used for LXC
root filesystems. Proxmox cannot extract an unprivileged template there. When
that exact failure is detected, the installer removes no data itself and
retries the already-cleaned creation in privileged mode. Pass
`--no-privileged-fallback` if you prefer it to stop until the host ACL
configuration is repaired.

### Unattended install

```bash
sudo NORDVPN_USER='token-user' NORDVPN_PASS='token-pass' \
  ./install-jellyfin-stack.sh --no-gui \
  --nas-export 192.168.1.10:/volume1/media \
  --gpu off
```

See all options with `./install-jellyfin-stack.sh --help`.

### Building the hosted bundle

Maintainers should build the archive from this repository, not from a
homelab-specific copy of the installer:

```bash
bash scripts/build-release.sh
```

The command prints the SHA-256 value that must be pinned by the hosted
bootstrap. This keeps private Proxmox storage, DNS, VLAN, and NAS defaults out
of public releases.

## Configuration

Portable settings are auto-detected or start blank; none of Nazz's storage,
DNS, VLAN, or NAS addresses are embedded in the public installer. Every default
can be overridden by a flag or environment variable. Key settings:

| Setting | Flag | Default |
|---------|------|---------|
| Proxmox root storage | `--storage` | auto-detected active `rootdir` storage |
| Template storage | `--template-storage` | auto-detected active `vztmpl` storage |
| Primary media type | `--media-storage nfs\|local` | NFS in unattended mode; prompted in guided mode |
| Onboard media pool | `--local-media-storage` | active Proxmox storage with the most free space |
| Onboard media size | `--local-media-size` | auto-sized from free space, up to 100 GB |
| NAS NFS export | `--nas-export` | required only for NFS mode |
| Second NAS (optional) | `--enable-qnap` / `--qnap-export` | disabled |
| Container DNS | `--nameserver` | auto-detect a usable non-loopback resolver |
| VLAN tag | `--vlan` | untagged |
| Timezone | `--timezone` | Proxmox host timezone |
| GPU passthrough | `--gpu auto\|nvidia\|amd\|off` | auto-detect |

Guided installs ask whether the container uses an untagged network or a tagged
VLAN. Choose the same VLAN as another working application container when the
Proxmox host uses a segmented network. Guided mode requires one password and
confirms it once; that password is used for the LXC `root` console and the
shared application admin login. Unattended mode generates a password only when
one was not supplied. `--root-password` can still set a separate LXC password.

Before installing packages, the installer requires stable IPv4 DNS and an
outbound HTTP connection to Debian's repository. APT updates treat partial
repository failures as errors and retry instead of continuing with stale lists.

Copy `jellyfin-stack/.env.example` to `.env` and fill it in to pin secrets, or
let the installer generate strong random secrets for you (stored at
`/opt/mediastack/.env`, mode `0600`, inside the LXC).

## Ports

| App | Port | | App | Port |
|-----|------|-|-----|------|
| Media Stack Home | 8088 | | Prowlarr | 9696 |
| Jellyfin | 8096 | | qBittorrent | 8080 |
| Jellyseerr | 5055 | | Lidarr | 8686 |
| Jellystat | 3000 | | Bazarr | 6767 |
| Profilarr | 6868 | | Kavita | 5000 |
| Sonarr | 8989 | | Homarr | 7575 |
| Radarr | 7878 | | Portainer | 9443 |

## Verifying an install

```bash
pct exec <CTID> -- /opt/mediastack/verify-media-stack.sh
```

Checks every core container, health, web endpoint, and the app-to-app wiring.
Homarr is treated as an optional dashboard and will not fail the check if it is down.

## Security notes

- Secrets are generated at runtime; nothing sensitive is committed to this repo.
- Do **not** commit a real `.env` — it is git-ignored.
- Keep admin apps (Portainer, the *arrs) on your internal network; only expose
  reviewed ports if you put a reverse proxy in front.

## License

MIT — see [LICENSE](LICENSE).
