# amnezia-pbr-openwrt

**Языки:** [English](README.md) · Русский (этот файл)

Установка на OpenWrt-роутер: **AmneziaWG** + **policy-based routing**
с **обходом RU-блоков** и опциональным слоем **zapret** (DPI desync),
плюс LuCI-панель которая всё это оборачивает.

Что получаешь на роутере:

- интерфейс `awg1` AmneziaWG (kmod + tools от
  [Slava-Shchipunov/awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt));
- policy-based routing (`pbr` + `luci-app-pbr`) — LAN-трафик по
  умолчанию идёт через `awg1`, но `.ru` TLD и текущий ipdeny RU IPv4
  список — напрямую через WAN (банки, госуслуги, mail.ru не туннелируются);
- `zapret` (DPI desync, от
  [remittor/zapret-openwrt](https://github.com/remittor/zapret-openwrt))
  ставится но **выключен** по умолчанию — включаешь из LuCI после
  того как найдёшь рабочую стратегию для своего провайдера;
- страница LuCI **Network → Amnezia** с:
  - статусом туннеля и PBR, переключатель в один клик;
  - еженедельным обновлением списка RU CIDR;
  - **Domain probe** — классифицирует как сайт ломается на прямом WAN;
  - **Verify list** — проверяет набор доменов после применения стратегии;
  - **Blockcheck** runner с live-логом + apply/revert рекомендованных
    nfqws стратегий.

## Установка

Два пути — выбирай один. Оба приводят к одному и тому же
сконфигурированному роутеру; разница в том как потом приходят
обновления.

**Перед любым путём положи свой Amnezia-экспортированный .conf** в
`/etc/amnezia/awg.conf` (файл со строками `Jc / Jmin / S* / H* / I*` в
`[Interface]` — экспорти из Amnezia desktop client: *Настройки → Соединение
→ Экспорт config*).

```sh
mkdir -p /etc/amnezia
vi /etc/amnezia/awg.conf
# вставить экспорт, сохранить, выйти
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
REL=v0.2.0   # или актуальный release tag

cd /tmp
for pkg in amnezia-pbr luci-app-amnezia; do
  wget -O "${pkg}.ipk" \
    "https://github.com/JonniK/amnezia-openwrt/releases/download/${REL}/${pkg}_0.2.0-1_all.ipk"
done

opkg install ./amnezia-pbr.ipk ./luci-app-amnezia.ipk
amnezia-pbr-setup     # скачивает AmneziaWG kmod + zapret, конфигурирует UCI
```

Нативная opkg-интеграция — `opkg upgrade amnezia-pbr` подхватывает
обновления wrappers без re-bootstrap. `opkg remove` чисто удаляет.
UCI-конфиг (`/etc/config/amnezia`) и `/etc/amnezia/awg.conf` помечены
как conffile, так что пользовательские правки переживают upgrade.

В любом из путей: WAN пингуется до и после каждого destructive шага,
сеть никогда не рестартуется целиком, `/tmp/openwrt-deploy.log`
заканчивается `DEPLOY_DONE` или `DEPLOY_FAILED`. Перезапускать после
любых правок безопасно — идемпотентно.

### Параметры установки

| Env var | По умолчанию | Что делает |
|---|---|---|
| `STEPS` | `3` | `1` = только AWG + firewall, `2` = +PBR, `3` = +обход RU |
| `AWG_CONF` | `/etc/amnezia/awg.conf` | Откуда читать ключи AWG |
| `REPO_REF` | `main` | Какую ветку/тег устанавливать |
| `AWG_VER` | `24.10.3` | Версия ipk от Slava-Shchipunov |

### Где что лежит

| Путь | Назначение |
|---|---|
| `/etc/amnezia/awg.conf` | Твой AmneziaWG конфиг (предоставляешь сам) |
| `/etc/amnezia/ru.cidr` | Актуальный ipdeny RU IPv4 список (обновляется еженедельно) |
| `/etc/amnezia/ru-update.json` | Стамп последнего обновления |
| `/etc/amnezia/blockcheck.json` | Стамп последнего запуска blockcheck |
| `/etc/amnezia/seed-must-tunnel.list` | Reference список известных anti-VPN / geo-block сайтов |
| `/etc/amnezia/zapret-backups/` | Backup'ы `NFQWS_OPT` для каждого Apply |
| `/opt/zapret/config` | Активный zapret конфиг (`NFQWS_OPT` живёт тут) |
| `/etc/pbr.d/99-lan-vpn.sh` | PBR include: LAN → awg1 |
| `/etc/pbr.d/ru-direct.sh` | PBR include: RU CIDR → WAN direct |

### Поддерживаемое железо

Протестировано на **aarch64 mediatek/filogic** (Xiaomi AX3000T, Banana Pi
BPI-R4 и т.п.) на OpenWrt 24.10.3.

Installer авто-определяет `DISTRIB_ARCH` и `DISTRIB_TARGET` чтобы взять
правильный AmneziaWG kmod ipk из релизов Slava-Shchipunov, поэтому
другие платформы должны работать если для них есть соответствующий ipk.
mips_24kc заявлен но не тестировался.

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
install.sh                  Публичный bootstrap (это запускают пользователи)
openwrt/
  install-amnezia-pbr.sh    Основной installer pipeline (на роутере)
  install-zapret.sh         zapret package + wrappers + nmap-ncat
  install-luci-app-amnezia.sh   LuCI menu/acl/view + cron
  install-luci-toggle.sh    LuCI System->CustomCommands toggle
  install-dnsmasq-full.sh   Замена на dnsmasq-full (нужен для nftset)
  configure-dnsmasq-ru-nftset.sh   .ru TLD -> pbr_ru_tld4 nftset
  awg-{toggle,status,ru-update}.sh    AWG обёртки
  pbr-{status,reload}.sh    PBR обёртки
  zapret-{toggle,status,blockcheck,apply,probe,verify}.sh   zapret обёртки
  seed-must-tunnel.list     Reference список geo-block сайтов
  pbr.d/                    PBR include файлы
  luci-app-amnezia/         LuCI app (menu, acl, view/main.js)
docs/                       Дизайн-заметки (plan-b: inverted PBR architecture)
dev/                        Maintainer-side SSH тулинг (не для пользователей)
local/                      Твой приватный AWG конфиг (gitignored)
```

## Лицензия

GPLv2. См. LICENSE.

## См. также

- [docs/plan-b-inverted-pbr.md](docs/plan-b-inverted-pbr.md) — дизайн
  следующей итерации архитектуры «direct по умолчанию + zapret +
  selective must-tunnel».
- [docs/ru-tld-bypass.ru.md](docs/ru-tld-bypass.ru.md) — как работает
  обход `.ru` TLD через dnsmasq nftset.
- [README.md](README.md) — English version.
