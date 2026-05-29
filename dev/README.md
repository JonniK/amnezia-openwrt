# dev/

Maintainer tooling. **Not** for end users — these scripts run from the
maintainer's workstation, not on the router itself.

End users install via the package (see top-level README and `install.sh`,
once published) which deploys everything to the router directly via opkg.

## What lives here

| Script | Purpose |
|---|---|
| `deploy-openwrt-safe.sh` | SSH-driven deploy of in-development changes to the maintainer's router. Backs up first, runs install steps in background on the router, polls until done. Reads `local/awg.conf` for AmneziaWG keys. |
| `openwrt-backup.sh` | Pull a snapshot of router UCI configs + opkg list + sysupgrade backup into `openwrt-backups/<label>/`. |
| `openwrt-restore.sh` | Restore from a labelled backup with `--uci-only` mode for configs-only. |
| `openwrt-emergency-internet.sh` | Strip VPN/PBR config on the router to recover internet if a deploy bricks routing. |

## Path convention

All four active scripts assume:

- repo root is one level up (`../`)
- `openwrt/` (deploy payload), `local/` (private AWG keys), and
  `openwrt-backups/` (snapshots) live at the repo root.

They auto-compute `REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"` at the top so
they work whether invoked as `./dev/deploy-openwrt-safe.sh`,
`dev/deploy-openwrt-safe.sh` from another cwd, or by absolute path.

## Override variables

| Var | Default | Purpose |
|---|---|---|
| `SSH_HOST` | `router` | SSH alias / hostname of the target router |
| `CONF_LOCAL` | `<repo>/local/awg.conf` | AmneziaWG config to upload (deploy only) |
| `BACKUP_ROOT` | `<repo>/openwrt-backups` | Where snapshots are stored |
| `STEPS` | `3` | Deploy depth: `1` AWG+PBR base, `2` +RU bypass, `3` full |
