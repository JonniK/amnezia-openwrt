# Шпаргалка команд (Amnezia + OpenWrt)

**Языки:** [English](CHEATSHEET.md) · Русский (этот файл)

Краткий список команд — контекст в [README.ru.md](README.ru.md) · [English](README.md).

---

## Установка

```sh
# One-liner installer (запускается на роутере)
wget -O - https://raw.githubusercontent.com/JonniK/amnezia-openwrt/main/install.sh | sh

# Или через .ipk пакеты
opkg install ./amnezia-pbr.ipk ./luci-app-amnezia.ipk
amnezia-pbr-setup        # скачать AmneziaWG kmod + zapret, настроить UCI
```

## Управление туннелями

```sh
amnezia-tunnel-ctl list-free                          # следующий свободный слот (awg2..awg5)
amnezia-tunnel-ctl add awg2 "$(cat /tmp/awg2.conf)" --label 'Backup'
amnezia-tunnel-ctl remove awg2
```

## Управление failover

```sh
amnezia-failover-ctl set-mode balance                 # load-balance по туннелям
amnezia-failover-ctl set-mode failover                # strict-priority (по умолчанию)
amnezia-failover-ctl set-sticky awg2                  # закрепить sticky трафик на awg2
amnezia-failover-ctl set-weight awg2 3                # поднять вес awg2 (режим balance)
amnezia-failover-ctl toggle awg2                      # включить / выключить awg2 в pool
amnezia-failover-ctl make-default awg2                # перенумеровать метрики: awg2 выигрывает
amnezia-failover-ctl force-pin awg2                   # весь pool через awg2 (fail-closed если упадёт)
amnezia-failover-ctl force-unpin                      # снять pin, вернуть выбор по метрикам
amnezia-failover-ctl restart awg2                     # перезапустить только awg2 (ifdown/ifup)
amnezia-failover-ctl set-routing-mode tunnel-default  # внешний трафик -> туннель, .ru -> прямо
amnezia-failover-ctl set-routing-mode direct-default  # всё -> WAN напрямую, allowlist -> туннель
amnezia-failover-ctl master off                       # fail-open: выключить VPN маршрутизацию + DoT
amnezia-failover-ctl master on                        # восстановить стек из сохранённых настроек
amnezia-failover-ctl set-source refilter_domains 1    # включить источник force-tunnel списка
amnezia-failover-ctl set-source refilter_domains 0    # выключить его
```

## Статус

```sh
amnezia-status                          # сводка: туннели, состояние failover, DoT уровень
cat /var/run/amnezia-failover.json      # live JSON: routing_mode, pool, exit_ip по туннелям
```

## Force allowlist

```sh
amnezia-force-update                    # скачать все включённые источники + загрузить
amnezia-force-load                      # слить кешированные списки + применить (без скачивания)
# Ручные записи (домены или IP, по одному на строку):
vi /etc/amnezia/force-tunnel.list
nft list set inet fw4 amnezia_force4 | head   # посмотреть загруженные IP/CIDR
```

## Зашифрованный DNS (DoT)

```sh
amnezia-dns-ctl enable
amnezia-dns-ctl disable
amnezia-dns-ctl set-provider quad9      # quad9 adguard dns0 mullvad google
amnezia-dns-ctl status
```

## Защита от DNS-утечек

```sh
amnezia-dnsleak-ctl enable    # перехват порта 53, блокировка DoT/DoH обхода от LAN
amnezia-dnsleak-ctl disable
amnezia-dnsleak-ctl status
```

## Auto-tunnel (опциональный авто-learning доменов)

```sh
amnezia-autotunnel enable     # установить cron + dnsmasq query-log сниппет
amnezia-autotunnel disable    # убрать cron + сниппет (добавленные домены сохраняются)
amnezia-autotunnel status
amnezia-autotunnel add example.com
amnezia-autotunnel remove example.com
```

## Бэкап / восстановление (запускать из dev/ на своей машине)

```sh
SSH_HOST=openWRT ./dev/openwrt-backup.sh before-changes
SSH_HOST=openWRT ./dev/openwrt-restore.sh before-changes
OPENWRT_RESTORE_YES=1 ./dev/openwrt-restore.sh before-changes   # без вопроса
SSH_HOST=openWRT ./dev/openwrt-emergency-internet.sh             # снести VPN, вернуть прямой WAN
```

## Проверить nft-сеты (на роутере)

```sh
nft list set inet fw4 amnezia_force4 | head    # текущий allowlist IP
nft list set inet fw4 amnezia_ru4 | head       # RU CIDR bypass список
```

## Проверить связность

```sh
ping -c 2 1.1.1.1                  # WAN пинг с роутера
nslookup openwrt.org 127.0.0.1    # DNS на роутере
curl -4 https://ifconfig.co/ip    # egress IP (должен быть exit VPN)
ifstatus awg1 | jsonfilter -e '@.up'   # туннель up/down
