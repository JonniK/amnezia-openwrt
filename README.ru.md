# AmneziaWG + OpenWrt (split tunnel)

**Языки:** [English](README.md) · Русский (этот файл)

Скрипты и заметки для развёртывания **AmneziaWG 2.0** на **OpenWrt** с **policy-based routing (PBR)**: трафик в российские сети идёт напрямую в WAN, остальной трафик с LAN — через VPN. Есть **бэкап и откат** без сброса к заводским настройкам.

## Что здесь сделано

1. **Маршрутизация «RU напрямую, всё остальное через VPN»**  
   Список подсетей РФ подгружается с [ipdeny.com `ru.zone`](https://www.ipdeny.com/ipblocks/data/countries/ru.zone) и заливается в nftables-множество PBR (`pbr_wan_4_dst_ip_user`). Для клиентов `192.168.1.0/24` правила отправляют нероссийские назначения через интерфейс `awg1`.

2. **Интеграция AmneziaWG в UCI**  
   Интерфейс `awg1`, зона файрвола `awg1`, форвардинг LAN → VPN, peer с `route_allowed_ips=0`, чтобы **не** тянуть default route целиком в WG — маршруты задаёт PBR.

3. **Установка пакетов AWG под конкретную сборку OpenWrt**  
   В `setup-amnezia-full.sh` зашиты версия OpenWrt-пакетов (`24.10.3`), архитектура (`aarch64_cortex-a53`) и target (`mediatek_filogic`) под релизы [awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt/releases). При другом роутере строки `VER` / `ARCH` / `TS` нужно поменять.

4. **Снимки конфигурации роутера** в `openwrt-backups/` (только локально, см. `openwrt-backups/.gitignore`):  
   Примеры меток: `clean-after-reset`, `before-amnezia`, `after-amnezia` — как назовёте при вызове `openwrt-backup.sh`.

5. **Файл `amnezia_sites_ru_geoip.json`** — JSON-снимок **[ipdeny `ru.zone`](https://www.ipdeny.com/ipblocks/data/countries/ru.zone)** (те же CIDR, конвертация в записи `{hostname,ip}`). В актуальных sh-скриптах на роутере по-прежнему качается сам **`ru.zone`**. **Подробности и обновление:** [docs/amnezia_sites_ru_geoip.ru.md](docs/amnezia_sites_ru_geoip.ru.md) · [EN](docs/amnezia_sites_ru_geoip.md).

6. **Клиентский экспорт Amnezia** (`vpn://…`) — только для приложения Amnezia на рабочей станции, не для UCI роутера.

## Файлы

| Файл / каталог | Назначение |
|----------------|------------|
| `setup-amnezia-full.sh` | **Основной сценарий по SSH:** залить импорт AWG, поставить kmod/tools/luci AmneziaWG + PBR, настроить UCI, firewall, `ru-direct.sh` + `99-lan-vpn.sh`, перезапуск сервисов. |
| `setup-openwrt-awg-pbr.sh` | Вариант деплоя: парсинг `.conf` **на вашей машине**, передача переменных по SSH (логика близка к «full», другая точка парсинга). |
| `setup-router-remote.sh` | Запуск **на роутере**: ожидает временный файл **`/tmp/awg-setup.conf`**, дальше UCI + PBR как выше. |
| `local/README.md` | Импорт по умолчанию (`local/awg.conf`, не в git). [English](local/README.md) · [Русский](local/README.ru.md) |
| `openwrt-backup.sh` | Снять с роутера архив: выбранные `/etc/config/*`, `uci export`, `opkg list-installed`, маршруты/правила, опционально `sysupgrade -b`. |
| `openwrt-restore.sh` | Восстановить снимок по метке; флаг `--uci-only` — только конфиги. Перед применением спрашивает подтверждение (или `OPENWRT_RESTORE_YES=1`). |
| `openwrt-emergency-internet.sh` | Аварийно выключить PBR/VPN, подчистить UCI/firewall/nft, вернуть типовой WAN DHCP + LAN `192.168.1.1/24`. |
| `openwrt-backups/<label>/` | Распакованный бэкап: `config/`, `meta/`, в корне `README.txt` с командами восстановления. |
| `amnezia_sites_ru_geoip.json` | Список CIDR для обхода через WAN (запасной вариант, не используется текущими sh-скриптами). [Док](docs/amnezia_sites_ru_geoip.ru.md) · [EN](docs/amnezia_sites_ru_geoip.md) |
| `docs/amnezia_sites_ru_geoip*.md` | Откуда взялся `amnezia_sites_ru_geoip.json` и как обновлять. |
| [CHEATSHEET.md](CHEATSHEET.md) · [CHEATSHEET.ru.md](CHEATSHEET.ru.md) | Шпаргалка команд |
| `.gitignore` | В корне: `local/*` (импорт с ключами), плюс ссылка на правила в `openwrt-backups/.gitignore`. |

## Требования

- В `~/.ssh/config` (или аналоге) хост для роутера (в скриптах по умолчанию **`router`** — задайте `SSH_HOST`).
- Переменные окружения (опционально):
  - `SSH_HOST` — хост SSH;
  - `CONF_LOCAL` — путь к декодированному `.conf` с ключами (по умолчанию **`local/awg.conf`**, см. `local/README.md` / `local/README.ru.md`);
  - `BACKUP_ROOT` — корень каталога бэкапов (по умолчанию **`openwrt-backups/`** в корне репозитория).

## Типовой порядок работ

1. Получить из Amnezia конфиг и **декодировать** в обычный `.conf`, положить по пути из `CONF_LOCAL` (по умолчанию **`local/awg.conf`**, см. `local/README.ru.md`).
2. Перед изменениями:  
   `./openwrt-backup.sh before-amnezia`
3. Полная установка с машины:  
   `./setup-amnezia-full.sh`  
   (при необходимости поправить `VER` / `ARCH` / `TS` внутри скрипта под свой роутер).
4. После проверки:  
   `./openwrt-backup.sh after-amnezia`

Проверка с клиента: например `curl ifconfig.me` — вне российских сайтов должен отображаться IP VPN.

## Откат и авария

- Восстановление из снимка:  
  `./openwrt-restore.sh before-amnezia`  
  или другая метка.
- Без бэкапа, если «всё умерло»:  
  `./openwrt-emergency-internet.sh`  
  Затем обновить DHCP на клиентах или переподключить Wi‑Fi.

## Безопасность

- Импорт AWG (`local/awg.conf` или любой путь в `CONF_LOCAL`) и **содержимое** `openwrt-backups/*` содержат **ключи и чувствительные данные**. В git не попадают: **`.gitignore`** и **`openwrt-backups/.gitignore`**. При утечке перевыпустите конфиг в Amnezia.
- Если что-то уже было закоммичено до этих правил, снимите с индекса: например `git rm --cached local/awg.conf`, `git rm -r --cached openwrt-backups/<метка>/` и т.п.

## Примечание по LAN

Скрипты заточены под подсеть **`192.168.1.0/24`**. При другой разметке LAN нужно править `99-lan-vpn.sh` / политики PBR в соответствующих `.sh`.

## Чеклист команд

**[CHEATSHEET.ru.md](CHEATSHEET.ru.md)** · [English](CHEATSHEET.md)

## FAQ

**В чём разница между `setup-amnezia-full.sh` и `setup-openwrt-awg-pbr.sh`?**  
`full` сам качает с GitHub IPK AmneziaWG под зашитые `VER`/`ARCH`/`TS`, парсит конфиг **на роутере** после заливки во **`/tmp/awg-setup.conf`**, добавляет include `99-lan-vpn.sh` и чуть иной порядок рестартов. `setup-openwrt-awg-pbr.sh` парсит `.conf` **на вашей машине** и передаёт значения в heredoc; пакеты AWG на роутере он не ставит — их нужно уже иметь или доставить отдельно.

**Сообщение `Missing …` (нет файла импорта).**  
Проверьте путь `CONF_LOCAL` или положите конфиг в **`local/awg.conf`** (см. `local/README.ru.md`). Пример:  
`CONF_LOCAL=/absolute/path/to/import.conf ./setup-amnezia-full.sh`.

**Ошибка загрузки `.ipk` / `opkg install` на роутере.**  
Чаще всего не совпали **архитектура** или **target** с [релизами awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt/releases). На роутере: `cat /etc/openwrt_release` и подставьте свои `ARCH` и `TS` в `setup-amnezia-full.sh` (и при необходимости `VER`).

**`curl ifconfig.me` показывает IP провайдера, а не VPN.**  
Убедитесь, что тест идёт на **не**-российский ресурс (часть «видимого» интернета может считаться RU по списку). Проверьте `ifstatus awg1`, статус PBR, что клиент в `192.168.1.0/24`. На роутере: смотрите вывод скрипта в конце (`awg ping`, `pbr`).

**Российские сайты открываются через VPN или наоборот — странно.**  
Списки ipdeny обновляются периодически; возможны пограничные случаи CDN. Имеет смысл перезапустить PBR после обновления зоны: на роутере `/etc/init.d/pbr restart` (скрипт `ru-direct.sh` подтянет `ru.zone` при необходимости).

**Можно ли использовать `amnezia_sites_ru_geoip.json` вместо ipdeny?**  
Текущие sh-скрипты его **не** подключают — нужен свой генератор / nft. JSON уже получен из того же **[`ru.zone`](https://www.ipdeny.com/ipblocks/data/countries/ru.zone)**; как пересобрать: [docs/amnezia_sites_ru_geoip.ru.md](docs/amnezia_sites_ru_geoip.ru.md) · [EN](docs/amnezia_sites_ru_geoip.md).

**У меня LAN не `192.168.1.0/24` или есть гостевая сеть.**  
Замените подсеть в `99-lan-vpn.sh` и в политиках PBR (`src_addr` / nft `ip saddr`) во всех задействованных скриптах, затем снова задеплойте или правьте UCI/`/etc/pbr.d` на роутере вручную.

**`openwrt-restore.sh` завис на вопросе `Continue?`**  
Для неинтерактивного запуска: `OPENWRT_RESTORE_YES=1 ./openwrt-restore.sh <метка>`.

**После restore/emergency клиенты без интернета.**  
Обновите DHCP на устройствах, переподключите Wi‑Fi или перезагрузите роутер.

**Нужен ли `git` / репозиторий для этой папки?**  
Нет. Достаточно SSH и POSIX shell; репозиторий удобен для версионирования скриптов и README **без** секретов — см. **`.gitignore`** и [CHEATSHEET.ru.md](CHEATSHEET.ru.md).
