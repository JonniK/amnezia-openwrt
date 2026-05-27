# Шпаргалка команд (Amnezia + OpenWrt)

**Языки:** [English](CHEATSHEET.md) · Русский (этот файл)

Краткий список команд — контекст в [README.ru.md](README.ru.md) · [English](README.md).

Выполняйте из **корня репозитория** (или задайте `BACKUP_ROOT` / `CONF_LOCAL` явно).

| Шаг | Команда |
|-----|---------|
| Проверить SSH к роутеру | `ssh router uptime` |
| Другой хост SSH | `SSH_HOST=myrouter ./openwrt-backup.sh my-label` |
| Бэкап с меткой по дате | `./openwrt-backup.sh` |
| Бэкап перед правками | `./openwrt-backup.sh before-amnezia` |
| Бэкап после успешной настройки | `./openwrt-backup.sh after-amnezia` |
| Полный деплой AWG + PBR (с хоста) | `./setup-amnezia-full.sh` |
| Деплой с другим конфигом | `CONF_LOCAL=/path/to/import.conf ./setup-amnezia-full.sh` |
| Альтернативный скрипт (парсинг .conf локально) | `./setup-openwrt-awg-pbr.sh` |
| Деплой только на роутере | Залить импорт в **`/tmp/awg-setup.conf`**, затем на роутере: `sh setup-router-remote.sh` |
| Восстановить снимок (с вопросом) | `./openwrt-restore.sh before-amnezia` |
| Восстановить без вопроса (CI/скрипты) | `OPENWRT_RESTORE_YES=1 ./openwrt-restore.sh before-amnezia` |
| Только UCI-конфиги из снимка | `./openwrt-restore.sh before-amnezia --uci-only` |
| Авария: убрать VPN/PBR | `./openwrt-emergency-internet.sh` |
| Проверка «вне РФ» с клиента | `curl -4 ifconfig.me` или открыть зарубежный сервис |
| Проверка на роутере (после SSH) | `ifstatus awg1; /etc/init.d/pbr status` |
| Множества обхода RU (роутер) | `nft list set inet fw4 pbr_wan_4_dst_ip_user \| head; nft list set inet fw4 pbr_ru_tld4 \| head` |
