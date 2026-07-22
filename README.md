# Jellyfin Media Stack — one-command Proxmox installer

Deploy a complete, auto-configured Jellyfin media stack into an unprivileged
Debian LXC on a Proxmox VE host with a single command. Optional NVIDIA GPU
transcoding, NFS media storage, and a guided terminal UI are all built in.

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
- An **NFS export** for media (required). A second NFS export (e.g. a QNAP) is optional.
- Optional: an NVIDIA GPU on the host for hardware transcoding
- A VPN account for Gluetun (defaults assume NordVPN; edit `docker-compose.yml`
  and the `.env` for other providers)

## Quick start

Run this on the Proxmox host as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/masternazz/nazz-media-stack/main/install.sh)"
```

> Requires the repository to be public. If it is private, either export a
> `GITHUB_TOKEN` that can read it, or use the clone method below.

Or clone and run:

```bash
git clone https://github.com/masternazz/nazz-media-stack.git
cd nazz-media-stack
sudo ./install-jellyfin-stack.sh
```

Running with no flags launches a guided terminal UI (whiptail) that prompts for
container ID, storage, network, NAS export, GPU mode, and the shared admin login.

### Unattended install

```bash
sudo NORDVPN_USER='token-user' NORDVPN_PASS='token-pass' \
  ./install-jellyfin-stack.sh --no-gui \
  --storage local-lvm \
  --nas-export 192.168.1.10:/volume1/media \
  --nameserver 1.1.1.1
```

See all options with `./install-jellyfin-stack.sh --help`.

## Configuration

Every default can be overridden by a flag or environment variable. Key ones:

| Setting | Flag | Default |
|---------|------|---------|
| Proxmox storage | `--storage` | `local-lvm` |
| NAS NFS export (**required**) | `--nas-export` | `nas.example.lan:/volume1/media` |
| Second NAS (optional) | `--enable-qnap` / `--qnap-export` | disabled |
| Container DNS | `--nameserver` | `1.1.1.1` |
| VLAN tag | `--vlan` | `6` |
| GPU passthrough | `--no-nvidia` / `--require-nvidia` | auto-detect |

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
