# Local AWG import

**Languages:** English (this file) · [Русский](README.ru.md)

Repository overview: [README.md](../README.md) · [README.ru.md](../README.ru.md).

Place your **decoded** WireGuard / Amnezia config as a plain `.conf` (`[Interface]` / `[Peer]`) in **`awg.conf`** here. That is the default path for `setup-amnezia-full.sh` and `setup-openwrt-awg-pbr.sh` (override with **`CONF_LOCAL`**).

You can use any path: `CONF_LOCAL=/path/to/your.conf ./setup-amnezia-full.sh`.

If the file lived elsewhere before, copy it to **`local/awg.conf`** or always pass **`CONF_LOCAL`**.

On a full deploy from your host, the import is copied to **`/tmp/awg-setup.conf`** on the router. For `setup-router-remote.sh`, upload the file there yourself.

**Optional (local only):** keep Amnezia desktop exports (`vpn://…`) next to this file, e.g. **`client-vpn-export.conf`** — router deploy scripts do not read them; it is just a convenient, git‑ignored place.
