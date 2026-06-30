# amnezia-pbr-openwrt

**Языки:** [English](README.md) · Русский (этот файл)

Установка на OpenWrt-роутер: **AmneziaWG** + **автоматический failover
по нескольким туннелям**, обход RU-блоков и опциональный слой **zapret**
(DPI desync), плюс LuCI-панель которая всё это оборачивает.

Что получаешь на роутере:

- До 5 интерфейсов `awgN` AmneziaWG (kmod + tools от
  [Slava-Shchipunov/awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt)).
- **Multi-tunnel failover** через procd-демон `amnezia-failover`:
  проверяет каждый туннель (свежесть handshake ИЛИ bound ping),
  debounces, переключает default route через `ip route replace` —
  pbr не используется.
  - Режим по умолчанию: **strict-priority failover** (`mode failover`
    в `config globals`). Туннель с наименьшим metric несёт весь трафик;
    sticky-туннель держит claude.ai и anthropic.com на одном выходном IP.
  - Опционально: **load-balance** (`mode balance`) — трафик
    распределяется по здоровым туннелям через iproute2 resilient
    nexthop groups. Включается полем `globals.mode`.
  - Fail-closed: когда все туннели упали, устанавливается blackhole
    default — LAN-трафик не уходит через WAN без шифрования.
- **Два режима маршрутизации**, переключаемых в рантайме (UCI `config.routing_mode`):
  - `tunnel-default` (по умолчанию): весь внешний трафик идёт через туннель;
    `.ru` TLD и RU CIDR идут напрямую через WAN.
  - `direct-default` (режим allowlist): WAN — путь по умолчанию; только
    адреса из force-tunnel списка (и sticky-адреса) идут через туннель.
    Полезен когда большинство трафика нормально работает напрямую + zapret,
    и только короткий список сайтов нужно гнать через туннель. Если список
    пуст — весь трафик идёт напрямую (fail-open для туннеля).
- **Нативный fw4 nft classifier**
  (`/etc/nftables.d/30-amnezia-classify.nft`) вместо pbr/luci-app-pbr.
  Трафик маркируется на prerouting и направляется в две iproute2-таблицы
  (`vpn_sticky` 100, `vpn_pool` 101). В режиме `direct-default` активируется
  отдельный фрагмент (`30-amnezia-classify-direct.nft`).
- `.ru` TLD и ipdeny RU IPv4 CIDR остаются немаркированными → через WAN
  (банки, госуслуги, mail.ru не туннелируются). Актуально только в режиме
  `tunnel-default`.
- **Allowlist (force-tunnel список)** для режима `direct-default`:
  - Curated-источники обновляются ежедневно в 03:15, кешируются в
    `/etc/amnezia/force.d/`. Включены по умолчанию: `itdoginfo_inside`
    (RKN-блокированные домены) и `itdoginfo_services` (geoblock-RU:
    OpenAI, Anthropic, Spotify-аналоги). Переключаемые: `refilter_domains`,
    `refilter_ip`, `antifilter`.
  - Ручные записи в `/etc/amnezia/force-tunnel.list` сливаются с
    источниками и никогда не перезаписываются авто-обновлением.
  - Домены попадают в nft-сет `amnezia_force4` через dnsmasq; IP/CIDR
    грузятся напрямую.
- **Добавление/удаление туннелей** в рантайме из LuCI-панели (вставить
  `.conf` или ссылку Amnezia `vpn://` — декодируется в браузере) или через
  `amnezia-tunnel-ctl add/remove`.
- `zapret` (DPI desync, от
  [remittor/zapret-openwrt](https://github.com/remittor/zapret-openwrt))
  ставится но **выключен** по умолчанию — включаешь из LuCI после
  того как найдёшь рабочую стратегию для своего провайдера.
- **IPv6 fail-closed**: LAN→WAN IPv6 forwarding дропается, LAN
  RA/DHCPv6/NDP выключены. Туннели несут только IPv4-трафик.
- Страница LuCI **Network → Amnezia** с:
  - статусом туннелей и failover, здоровье и handshake age каждого туннеля;
  - переключателем туннеля и режима в один клик;
  - **Форма добавления туннеля** (вставить `.conf` или ссылку `vpn://`) и
    кнопка **Remove** на каждой строке туннеля;
  - **Выбор режима маршрутизации** (tunnel-default / direct-default);
  - **Источники allowlist** с чекбоксами включения, кнопкой "Update now"
    и текстовым полем для ручных записей;
  - ежедневным обновлением force-tunnel списка и еженедельным RU CIDR;
  - **Domain probe** — классифицирует как сайт ломается на прямом WAN;
  - **Verify list** — проверяет набор доменов после применения стратегии;
  - **Blockcheck** runner с live-логом + apply/revert рекомендованных
    nfqws стратегий.

## Скриншоты

| | |
|---|---|
| ![Обзор панели](docs/screenshots/luci-amnezia-overview.png) | ![Domain probe](docs/screenshots/luci-amnezia-probe.png) |
| Туннель + failover + RU список + zapret статус, в одном месте. | Пробить домен, получить verdict + рекомендацию. |
| ![Verify list](docs/screenshots/luci-amnezia-verify.png) | ![Blockcheck](docs/screenshots/luci-amnezia-blockcheck.png) |
| Перепробить N доменов после Apply с summary-чипами и action-подсказкой. | Запустить апстримный blockcheck.sh с live-логом; в один клик Apply рекомендованной nfqws стратегии. |

## Установка

Два пути — выбирай один. Оба приводят к одному и тому же
сконфигурированному роутеру; разница в том как потом приходят
обновления.

**Перед любым путём положи свой Amnezia-экспортированный .conf** в
`/etc/amnezia/awg1.conf` (файл со строками `Jc / Jmin / S* / H* / I*` в
`[Interface]` — экспорти из Amnezia desktop client: *Настройки → Соединение
→ Экспорт config*). Для нескольких туннелей добавь
`/etc/amnezia/awg2.conf`, `/etc/amnezia/awg3.conf`, … до `awg5.conf`.

```sh
mkdir -p /etc/amnezia
vi /etc/amnezia/awg1.conf      # вставить экспорт, сохранить, выйти
# опциональный второй туннель:
vi /etc/amnezia/awg2.conf
```

### Путь A: one-line installer (самый простой)

```sh
wget -O - https://raw.githubusercontent.com/JonniK/amnezia-openwrt/main/install.sh | sh
```

Скачивает tarball репо, ставит wrappers в `/usr/bin/`, запускает
install pipeline. Обновления — пере-запуск той же команды. Подходит
для первой установки или разовых сетапов.

### Путь B: opkg .ipk пакеты (нативный, обновляемый)

```sh
ARCH=$(. /etc/openwrt_release && echo "$DISTRIB_ARCH")
REL=v0.2.0-r3   # или актуальный release tag
VER=0.2.0-r3

cd /tmp
for pkg in amnezia-pbr luci-app-amnezia; do
  wget -O "${pkg}.ipk" \
    "https://github.com/JonniK/amnezia-openwrt/releases/download/${REL}/${pkg}_${VER}_all.ipk"
done

opkg install ./amnezia-pbr.ipk ./luci-app-amnezia.ipk
amnezia-pbr-setup     # скачивает AmneziaWG kmod + zapret, конфигурирует UCI
```

Нативная opkg-интеграция — `opkg upgrade amnezia-pbr` подхватывает
обновления без re-bootstrap. `opkg remove` чисто удаляет.
UCI-конфиг (`/etc/config/amnezia`) и `/etc/amnezia/awg*.conf` помечены
как conffile, так что пользовательские правки переживают upgrade.

В любом из путей: WAN пингуется до и после каждого destructive шага,
сеть никогда не рестартуется целиком, `/tmp/openwrt-deploy.log`
заканчивается `DEPLOY_DONE` или `DEPLOY_FAILED`. Перезапускать после
любых правок безопасно — идемпотентно.

### Параметры установки

| Env var | По умолчанию | Что делает |
|---|---|---|
| `STEPS` | `3` | `1` = только AWG + firewall, `2` = +routing, `3` = +обход RU |
| `AWG_CONF` | `/etc/amnezia/awg1.conf` | Откуда читать ключи AWG |
| `REPO_REF` | `main` | Какую ветку/тег устанавливать |
| `AWG_VER` | `24.10.3` | Версия ipk от Slava-Shchipunov |

### Где что лежит

| Путь | Назначение |
|---|---|
| `/etc/amnezia/awg1.conf` … `awg5.conf` | Твои AmneziaWG конфиги (предоставляешь сам; также пишет `amnezia-tunnel-ctl add`) |
| `/etc/config/amnezia` | UCI-конфиг: failover globals, per-tunnel настройки, routing_mode, секции force_source |
| `/etc/nftables.d/30-amnezia-classify.nft` | Активный fw4 prerouting classifier (перегенерируется при смене режима) |
| `/etc/iproute2/rt_tables.d/amnezia.conf` | Именованные routing tables: `vpn_sticky` (100), `vpn_pool` (101) |
| `/etc/amnezia/ru.cidr` | Актуальный ipdeny RU IPv4 список (обновляется еженедельно) |
| `/etc/amnezia/ru-update.json` | Стамп последнего обновления RU CIDR |
| `/etc/amnezia/blockcheck.json` | Стамп последнего запуска blockcheck |
| `/etc/amnezia/seed-sticky-domains.list` | Домены, закреплённые на sticky-туннеле (по умолчанию: claude.ai, anthropic.com) |
| `/etc/amnezia/zapret-backups/` | Backup'ы `NFQWS_OPT` для каждого Apply |
| `/opt/zapret/config` | Активный zapret конфиг (`NFQWS_OPT` живёт тут) |
| `/var/run/amnezia-failover.json` | Live состояние failover (читает LuCI-панель) |
| `/etc/amnezia/force-tunnel.list` | Ручные записи allowlist (домены/IP); авто-обновление никогда не перезаписывает |
| `/etc/amnezia/force.d/` | Кеш авто-обновления: по одному `.list`-файлу на каждый включённый источник |
| `/etc/amnezia/force-update.json` | Стамп последнего обновления force-списка (счётчики по источникам + статус) |

### Настройка нескольких туннелей

Все настройки failover живут в `/etc/config/amnezia` (UCI). Редактировать
через `uci`-команды или LuCI → Network → Amnezia.

**`config globals 'globals'`** — глобальные настройки failover:

| UCI-поле | По умолч. | Описание |
|---|---|---|
| `globals.mode` | `failover` | `failover` = strict-priority (один exit IP); `balance` = load-balance по здоровым туннелям |
| `globals.sticky_target` | `awg1` | Туннель для sticky-маркированного трафика (claude.ai, anthropic.com) |

**`config tunnel 'awgN'`** — одна секция на туннель (awg1 … awg5):

| UCI-поле | По умолч. | Описание |
|---|---|---|
| `awgN.enabled` | `1` | `1` = включить в failover pool, `0` = исключить |
| `awgN.label` | — | Человекочитаемое имя в LuCI-панели |
| `awgN.metric` | N | Меньше = выше приоритет в режиме failover |
| `awgN.weight` | `1` | Относительный вес в режиме balance |
| `awgN.track_ip` | `1.1.1.1` | IP для bound ping health-check когда handshake устарел |

**Пример — два туннеля, awg1 primary, awg2 backup:**

```sh
uci set amnezia.globals.mode=failover
uci set amnezia.globals.sticky_target=awg1

uci set amnezia.awg1=tunnel
uci set amnezia.awg1.enabled=1
uci set amnezia.awg1.label='Primary'
uci set amnezia.awg1.metric=1
uci set amnezia.awg1.weight=1

uci set amnezia.awg2=tunnel
uci set amnezia.awg2.enabled=1
uci set amnezia.awg2.label='Backup'
uci set amnezia.awg2.metric=2
uci set amnezia.awg2.weight=1

uci commit amnezia
/etc/init.d/amnezia-failover restart
```

Демон `amnezia-failover` перечитывает UCI при каждом запуске, поэтому
после изменения конфига достаточно `restart`.

**Runtime control helper** — `amnezia-failover-ctl`:

```sh
amnezia-failover-ctl set-mode balance        # переключить в load-balance
amnezia-failover-ctl set-mode failover       # вернуть strict-priority
amnezia-failover-ctl set-sticky awg2         # закрепить sticky на awg2
amnezia-failover-ctl set-weight awg2 3       # поднять вес awg2 в balance
amnezia-failover-ctl toggle awg2             # включить/выключить awg2 в pool
amnezia-failover-ctl set-routing-mode direct-default   # переключить в режим allowlist
amnezia-failover-ctl set-routing-mode tunnel-default   # вернуть туннель по умолчанию
amnezia-failover-ctl set-source refilter_domains 1     # включить источник force-списка
amnezia-failover-ctl set-source refilter_domains 0     # выключить его
```

`set-mode`, `set-sticky`, `set-weight`, `toggle` коммитят UCI и перезапускают монитор.
`set-routing-mode` перегенерирует активный classifier, запускает `amnezia-force-load`,
перезагружает fw4 (в фоновом subshell, SSH не рвётся), и сбрасывает conntrack pool/sticky
метки чтобы существующие потоки немедленно пересмотрели маршрут.
`set-source` только коммитит UCI; изменение вступает в силу при следующем
запуске `amnezia-force-update`.

### Управление туннелями в рантайме

Добавляй и удаляй туннели из LuCI-панели (Network → Amnezia → форма "Add tunnel"
и кнопка Remove на каждой строке) или из командной строки:

```sh
amnezia-tunnel-ctl list-free                        # показать следующий свободный слот (exit 3 если все заняты)
amnezia-tunnel-ctl add awg2 "$(cat /tmp/awg2.conf)" --label 'Backup'
amnezia-tunnel-ctl remove awg2                      # снести и убрать из UCI
```

`add` валидирует `.conf`-тело (требует PrivateKey, PublicKey, хост и порт Endpoint),
пишет конфиг в `/etc/amnezia/<name>.conf` (права 600), создаёт UCI-секции
network/firewall/amnezia, поднимает интерфейс и перезапускает failover-монитор.

`remove` сначала останавливает монитор, гасит интерфейс, удаляет все UCI-секции
и conf-файл, затем запускает монитор на оставшемся наборе туннелей. Отказывает
(exit 2) если туннель является текущим sticky target или если удаление оставит
firewall VPN-зону без членов — переназначь sticky (`set-sticky`) или оставь
хотя бы один туннель.

Максимум 5 туннелей (`awg1` … `awg5`).

**Из LuCI-панели:** вставь `.conf`-файл напрямую ИЛИ ссылку Amnezia `vpn://` —
ссылка декодируется в браузере (base64url + zlib + JSON-извлечение) и показывается
для проверки перед отправкой. Бэкенд никогда не получает сырую `vpn://`-ссылку.

### Источники allowlist

`amnezia-force-update` скачивает каждую включённую секцию `force_source` и сохраняет
результат в `/etc/amnezia/force.d/<source>.list`. При ошибке скачивания старый
кеш сохраняется. После скачивания вызывает `amnezia-force-load`.

`amnezia-force-load` сливает все `force.d/*.list` с ручным файлом
`/etc/amnezia/force-tunnel.list`, дедублирует, классифицирует каждую строку:

- **IP/CIDR** — грузятся напрямую в nft-сет `amnezia_force4`.
- **Домены** — пишутся в UCI-секцию `dhcp.amnezia_force`; dnsmasq перезапускается
  только если список доменов реально изменился.

Сет `amnezia_force4` волатилен (сбрасывается при каждом `fw4 reload`).
Hotplug-скрипт (`/etc/hotplug.d/firewall/99-amnezia-force-load`) и
boot-init (`/etc/init.d/amnezia-force-load`, START=96) автоматически
перезаполняют сет после каждой перезагрузки fw4 и при загрузке.

Источники и их умолчания:

| UCI-секция | По умолч. | Покрытие |
|---|---|---|
| `itdoginfo_inside` | **вкл** | RKN-блокированные домены (Russia/inside-raw.lst) |
| `itdoginfo_services` | **вкл** | Geoblock-RU сервисы — OpenAI, Anthropic, аналоги Spotify (Categories/geoblock.lst) |
| `refilter_domains` | выкл | Re-filter расширенный список доменов (1andrevich/Re-filter-lists) |
| `refilter_ip` | выкл | Re-filter IP/CIDR список (тот же репо) |
| `antifilter` | выкл | antifilter.download список доменов |

Переключать через `amnezia-failover-ctl set-source <name> 0|1` или чекбоксы LuCI.
Авто-обновление запускается ежедневно в **03:15** через cron (`/etc/crontabs/root`).
Для ручного запуска:

```sh
amnezia-force-update   # скачать + загрузить (как cron)
amnezia-force-load     # слить + применить уже скачанные кеши
```

Ручные записи в `/etc/amnezia/force-tunnel.list` всегда сливаются и
никогда не перезаписываются `amnezia-force-update`.

### Поддерживаемое железо

Протестировано на **aarch64 mediatek/filogic** (Xiaomi AX3000T, Banana Pi
BPI-R4 и т.п.) на OpenWrt 24.10.3.

Installer авто-определяет `DISTRIB_ARCH` и `DISTRIB_TARGET` чтобы взять
правильный AmneziaWG kmod ipk из релизов Slava-Shchipunov, поэтому
другие платформы должны работать если для них есть соответствующий ipk.
mips_24kc заявлен но не тестировался.

## Upgrade с pbr-based установки

Существующие установки с `pbr` + `luci-app-pbr` мигрируются автоматически
при запуске `amnezia-pbr-setup --migrate`:

1. Устанавливается нативный nft classifier (`30-amnezia-classify.nft`).
2. `@amnezia_ru4` nftset заполняется из сохранённого CIDR-файла.
   Если set пустой — миграция прерывается с rollback (gate безопасности).
3. dnsmasq перенаправляется со старых pbr nftsets на новые amnezia nftsets.
4. Старые must-tunnel домены мигрируют в sticky domain list.
5. `pbr` и `luci-app-pbr` останавливаются, выключаются и удаляются через opkg.
6. Firewall zones обновляются под все активные `awgN`; правило
   `amnezia_block_quic` **не трогается**.
7. LAN IPv6 RA/DHCPv6/NDP выключаются (IPv6 fail-closed).

Правило `amnezia_block_quic` (блокирует QUIC/UDP-443, заставляя
claude.ai работать по TCP через туннель) сохраняется через миграцию.

Для ручной валидации на железе — смотри
[`dev/spike-multitunnel-runbook.md`](dev/spike-multitunnel-runbook.md).

## Когда zapret помогает, а когда нет

zapret делает DPI desync на исходящих пакетах после того как они ушли с
роутера, но до того как они дошли до ТСПУ провайдера. Он помогает когда:

- Сайт **DPI-блокирован**: ТСПУ пропускает SYN, парсит ClientHello SNI,
  RST'ит соединение. zapret переписывает ClientHello (split, fakedsplit,
  multidisorder и т.п.) чтобы SNI не парсился. Это классический случай
  под который он сделан.

zapret **не поможет** когда:

- Сайт **SYN-блокирован**: ТСПУ дропает первый пакет handshake'а по
  destination IP. zapret работает с пакетами которые до него дошли;
  если SYN убит выше — нечего десинхронить. В РФ в 2026 это основной
  режим блокировки для многих западных сервисов (Instagram, Facebook,
  X, LinkedIn, часто YouTube).
- Сайт делает **server-side anti-VPN** (Cloudflare `cf-mitigated`,
  region-чек OpenAI, Netflix). Блокировка по IP клиента, и никакой
  packet-level десинк не меняет IP. Помогает только туннель (с
  не-палевным exit'ом).

LuCI-панель различает это тремя инструментами:

- **Domain probe** классифицирует один домен: `direct_ok`,
  `direct_dpi_blocked`, `direct_geoblocked` или `direct_unreachable`.
- **Blockcheck** запускает апстримный `/opt/zapret/blockcheck.sh` и
  показывает рекомендованную `--dpi-desync=...` стратегию когда
  что-то срабатывает.
- **Verify list** перепробивает список доменов с уже применённой
  стратегией в реальном времени — видишь работает ли рекомендация
  на твоих реальных целях (blockcheck часто даёт false positive
  тестируя против iana.org IP, а не реального destination).

Если большинство нужных тебе блокированных сайтов SYN-блокированы,
правильный ответ — оставить zapret выключенным и отправлять эти домены
через туннель. zapret максимально ценен когда позволяет оставлять
высокотрафиковые DPI-only сайты на прямом WAN, разгружая туннель.

## Структура репозитория

```
install.sh                          Публичный bootstrap (это запускают пользователи)
openwrt/
  install-amnezia-pbr.sh            Основной installer + migration pipeline (на роутере)
  amnezia-failover                  procd failover monitor daemon
  amnezia-failover-ctl.sh           Control helper (set-mode, set-sticky, set-weight, toggle,
                                      set-routing-mode, set-source)
  amnezia-failover.init             procd init script для amnezia-failover (ставит fwmark rules)
  amnezia-tunnel-ctl.sh             Добавление / удаление туннелей (add, remove, list-free)
  amnezia-force-load.sh             Слияние force.d/ + ручной список -> amnezia_force4 + dnsmasq
  amnezia-force-update.sh           Скачивает включённые force_source списки, кеширует, вызывает force-load
  amnezia-force-load.init           Boot init (START=96) для заполнения amnezia_force4
  99-amnezia-force-load.hotplug     Firewall hotplug: заполнить amnezia_force4 после fw4 reload
  amnezia-ru-cidr.sh                Заполнение @amnezia_ru4 nftset из persist / fetch
  amnezia-ru-load.init              Boot + hotplug loader для amnezia_ru4
  amnezia-status.sh                 Status summary
  configure-dnsmasq-amnezia.sh      Настройка dnsmasq nftset секций (RU TLD + sticky + force-list)
  nftables.d/30-amnezia-classify.nft        fw4 classifier для режима tunnel-default
  nftables.d/30-amnezia-classify-direct.nft fw4 classifier для режима direct-default (allowlist)
  iproute2-amnezia-rt_tables.conf   Именованные routing tables (vpn_sticky 100, vpn_pool 101)
  seed-sticky-domains.list          Домены на sticky-туннеле (claude.ai, anthropic.com)
  force-tunnel.list                 Seed-файл для ручных записей allowlist (поставляется пустым)
  lib/amnezia-common.sh             Общие константы + helpers (MAX_TUNNELS=5)
  lib/amnezia-routing.sh            iproute2 / nft / firewall helpers (routing_emit_classifier)
  lib/amnezia-tunnel-lib.sh         Парсер .conf + UCI-генератор для amnezia-tunnel-ctl
  install-zapret.sh                 zapret package + wrappers + ncat-full
  install-luci-app-amnezia.sh       LuCI menu/acl/view + cron
  awg-{toggle,status,ru-update}.sh  AWG обёртки
  zapret-{toggle,status,blockcheck,apply,probe,verify}.sh   zapret обёртки
  luci-app-amnezia/                 LuCI app (menu, acl, view/main.js, decode-vpn.mjs)
config/amnezia                      Пример UCI конфига (поставляется в пакете)
docs/                               Дизайн-заметки
dev/                                Maintainer SSH тулинг + spike runbooks + VM test harness
local/                              Твой приватный AWG конфиг (gitignored)
```

## Лицензия

GPLv2. См. LICENSE.

## См. также

- [`dev/spike-multitunnel-runbook.md`](dev/spike-multitunnel-runbook.md) — ручная
  последовательность hardware-валидации multi-tunnel failover.
- [docs/plan-b-inverted-pbr.md](docs/plan-b-inverted-pbr.md) — исходный дизайн
  архитектуры «direct по умолчанию + zapret + selective must-tunnel»,
  реализованной в виде режима `direct-default`.
- [docs/ru-tld-bypass.ru.md](docs/ru-tld-bypass.ru.md) — как работает
  обход `.ru` TLD через dnsmasq nftset.
- [README.md](README.md) — English version.
