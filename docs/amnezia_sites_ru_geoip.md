# `amnezia_sites_ru_geoip.json`

**Languages:** English · [Русский](amnezia_sites_ru_geoip.ru.md)

## What it is

- A **large JSON snapshot** of IPv4 **CIDR prefixes** for experiments around “Russian destinations → WAN, everything else → VPN” routing.
- **Shape:** a JSON array of objects `{ "hostname": "<string>", "ip": "<string>" }`. In this snapshot many rows use the **same CIDR** in both fields (the export treated each prefix as both “name” and “address”).
- **Not wired into the shell scripts** in this repository. Deploy scripts load **Russia** prefixes from **[ipdeny `ru.zone`](https://www.ipdeny.com/ipblocks/data/countries/ru.zone)** on the router instead (smaller, easy to refresh).

## Source

The CIDR set matches **[ipdeny Russia IPv4 zones](https://www.ipdeny.com/ipblocks/data/countries/ru.zone)** (`ru.zone`). The JSON file is a **converted snapshot** of that list: each non-empty line became `{ "hostname": "<cidr>", "ip": "<cidr>" }` (same value in both fields). The filename is historical; the data is **not** a third-party GeoIP product export.

## How to refresh it

1. **On the router / in scripts:** keep using **`ru.zone`** directly (see `ru-direct.sh` in the deploy scripts). Refresh by re-running deploy or `/etc/init.d/pbr restart` so `wget` pulls the latest file.
2. **To regenerate this JSON from `ru.zone` on your machine** (same shape as in the repo):
   - Download: `wget -O ru.zone https://www.ipdeny.com/ipblocks/data/countries/ru.zone`
   - Strip comments/blank lines, then turn each CIDR line into `{hostname, ip}` (e.g. small `awk`/`jq`/`python` — one object per line, both fields equal to the CIDR).
   - Validate: `jq empty amnezia_sites_ru_geoip.json`
   - Replace `amnezia_sites_ru_geoip.json` in the repo root and commit, e.g. `chore: refresh RU CIDR JSON from ipdeny ru.zone`.

## Repository size

The file is **big**; to keep clones small you can stop tracking it: uncomment `# amnezia_sites_ru_geoip.json` in the root `.gitignore` and keep the snapshot in GitHub **Releases** or outside git.
