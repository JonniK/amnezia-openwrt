# Обход туннеля для зоны `.ru` (DNS → nftables)

Скрипты развёртывания настраивают **два** механизма «российский трафик напрямую в WAN»:

1. **`ru.zone` (ipdeny)** — `ru-direct.sh` заполняет множество `pbr_wan_4_dst_ip_user` **IPv4-подсетями** РФ.
2. **`*.ru` через dnsmasq** — по возможности ставится **`dnsmasq-full`**; в UCI `dhcp` добавляется секция **`config ipset`** (`pbr_ru_tld`: `domain=.ru`, `name=pbr_ru_tld4`, `table=fw4`, `table_family=inet`) — в OpenWrt 24+ старый `dhcp.@dnsmasq[0].nftset` **игнорируется** init-скриптом dnsmasq.  
   В множество **`pbr_ru_tld4`** попадают **A-записи** имён с суффиксом `.ru`.  
   В `99-lan-vpn.sh` для `ip daddr @pbr_ru_tld4` делается `return` (без метки VPN), как и для ipdeny-множества.

Определение множества — в **`/etc/nftables.d/15-pbr-ru-tld4.nft`**, чтобы оно переживало обычные перезапуски **firewall4**.

## Зачем это

- **CDN / anycast**: IP может быть вне `ru.zone`, а имя — `*.ru`; путь через dnsmasq всё равно отправит **разрешённые** адреса в обход туннеля.
- **Первый запрос**: пока имя не резолвилось через dnsmasq роутера, в множестве нет IP — первое соединение может пойти в VPN, пока не отработает DNS.

## Почему DNS иногда «тупит»

Частые причины:

1. **Холодный кэш** — первый запрос к `.ru` должен завершиться, прежде чем nft наполнится; дальше быстрее (при наличии `dnsmasq-full` выставляется **`cachesize=8192`**).
2. **Апстрим** — если DNS уходит в туннель или на далёкие резолверы, проверьте **DNS на WAN / DHCP**; клиенты должны ходить в DNS **роутера**, если нужно заполнение nftset на нём.
3. **Только IPv4** — в множество попадают только **A** (`4#…`); чистый IPv6 не попадает в `pbr_ru_tld4`.

По желанию: **`list server '/.ru/<IP-резолвера>'`** в dnsmasq — отдельные апстримы только для `.ru` (доступные **без** VPN при split-DNS).

## Пакеты

- Замена **`dnsmasq`** на **`dnsmasq-full`** на время `opkg` может кратко ронять DNS; сначала пробуем просто **`opkg install dnsmasq-full`**, при неудаче — remove+install с **откатом на `dnsmasq`**, если full не встал.
- Если **`dnsmasq-full`** нет, `openwrt/configure-dnsmasq-ru-nftset.sh` пропускается (в лог — заметка); обход по **ipdeny** остаётся.

## Аварийная зачистка

`openwrt-emergency-internet.sh` удаляет **`/etc/nftables.d/15-pbr-ru-tld4.nft`**, секцию **`pbr_ru_tld`** (и устаревший list `nftset`) из dhcp и чистит **`/etc/pbr.d`**.

## См. также

- [amnezia_sites_ru_geoip.ru.md](amnezia_sites_ru_geoip.ru.md) — источник `ru.zone`.
