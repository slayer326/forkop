# Forkop Technical Audit

Аудируемый снимок: `slayer326/forkop` `main`, `bbd7a2d8bea42161f23207cdaa273579cc398cc8`, 25.09.2026. Рабочий fork: `Asofwar/forkop`, ветка `audit/technical-audit`. Аудит статический с локальными CI-подобными тестами; испытания на OpenWrt, реальной сети и управляемом LuCI-пользователе не проводились. `Confirmed` ниже означает доказанный путь в исходном коде, а не подтверждённый инцидент на роутере.

## Executive summary

**Critical: 0; High: 3; Medium: 7; Low: 0.** Наиболее опасные: F-001 (права `read` позволяют root-действия и чтение секретов), F-002 (ошибка reload оставляет DPI-процессы остановленными), F-003 (reload подтверждает успех при неудачном запуске DPI), F-005 (допустимый hostname Bootstrap DNS создаёт неработающую конфигурацию), F-009 (полный сброс nftables оставляет активный sing-box без перехвата трафика).

Основной риск сосредоточен на границах между компонентами: ACL → root CLI, reload → DPI процессы, UCI DNS → JSON sing-box, установщик → менеджер пакетов. Обычный `fw4 reload` **не** удаляет отдельную таблицу Forkop; подробности в «False positives investigated». Некоторые риски проявляются только при дополнительном событии (сбой запуска процесса, прерывание установки, полный `fw4 flush`), которое локальные тесты не моделируют.

Проверки: синтаксис всех backend `.uc` прошёл `ucode -c` и `ucode -S -c`; frontend Vitest — 45 файлов, 512 тестов; ESLint — без ошибок. Backend CI-скрипты `tests/*.sh`: 114 запущены, 112 прошли сразу; `forkop_release_sync.sh` прошёл повторно после установки алиаса `python`. `list_cache.sh` на WSL отверг фиктивный порог `999999999999` байт как «недостаток места», поскольку `/tmp` на этой машине располагает большим объёмом. Это ограничение среды теста; на OpenWrt сценарий не проверен. Тесты используют фикстуры, подмены команд и временные каталоги; успешный прогон не доказывает работу nft/procd/dnsmasq на устройстве.

## Architecture and lifecycle

`fe-app-forkop/src` формирует LuCI UI, а `luci-app-forkop` содержит развёрнутый JS и ACL. UI читает/пишет UCI `forkop`, вызывает `rpcd file.exec` для `/usr/bin/forkop` и `/etc/init.d/forkop`. CLI в `forkop/files/usr/bin/forkop` маршрутизирует команды к ucode. `service/initd.uc` и `service/lifecycle.uc` управляют запуском, блокировками, reload и procd-сервисом sing-box. `config/validator.uc` проверяет UCI; `singbox/generator.uc`, `singbox/dns.uc` и `singbox/route.uc` собирают JSON. `nft/apply.uc` создаёт отдельную таблицу `inet ForkopTable`, mangle/output, DNS redirect, TPROXY и policy route. `components/updates.uc` обновляет списки/подписки, `components/action.uc` — пакеты компонентов и Forkop. Zapret/Zapret2 идут через NFQUEUE; ByeDPI — локальный SOCKS/ciadpi. Итоговый путь: LuCI → UCI → lifecycle → sing-box JSON/процессы → nftables/TPROXY → DNS → WAN/прокси.

Жизненный цикл: `install.sh` меняет feed, ставит backend/UI/sing-box и запускает postinst; первый старт валидирует UCI, готовит DNS/nft/sing-box; изменение UCI подаёт procd-триггер; reload строит план, кандидат nft/JSON и переводит процессы; списки и подписки обновляются через отдельные задания с кэшем; обновления компонентов идут через `components/action.uc`; обновление Forkop вызывает пакетный postinst; после reboot procd поднимает сервис; `full_uninstall` удаляет его состояние и пакеты. Дефекты в отчёте привязаны к конкретным переходам этой цепи.

## Findings

### F-001 — LuCI `read` разрешает привилегированные действия и чтение секретов

**Severity:** High
**Confidence:** Confirmed
**Area:** security / LuCI / RPC
**Origin:** Inherited from upstream

**Files:** `luci-app-forkop/root/usr/share/rpcd/acl.d/luci-app-forkop.json:4`, `:6`, `:9`, `:45`; `forkop/files/usr/bin/forkop:124`, `:126`, `:133`, `:134`, `:156`, `:158`; `forkop/files/usr/lib/diagnostics/runtime.uc:794`, `:810`.

**Problem.** ACL `read` даёт `file.exec` для общего CLI и init-скрипта, а также `file.read` для сырого sing-box JSON. `rpcd file.exec` авторизует исполняемый путь, а аргументы передаёт вызывающий. CLI не различает роли: тот же путь содержит `stop`, `disable`, `full_uninstall` и `show_config raw`/`show_sing_box_config raw`. Следовательно, выделенный пользователь LuCI с правом только чтения Forkop может управлять root-сервисом и получить секреты из UCI/JSON. Это не анонимный доступ и не доказательство произвольного shell RCE.

**Trigger.** Выдать пользователю LuCI только `luci-app-forkop` read ACL; с его сессией вызвать `file.exec` с `command=/usr/bin/forkop`, `params=["show_sing_box_config","raw"]` или `params=["stop"]`. Деструктивную команду на рабочем роутере для проверки не запускать.

**Impact.** Утечка адресов подписок, UUID/паролей прокси и остановка/удаление сервиса вопреки read-only роли.

**Evidence.** `ACL read → rpcd file.exec → forkop.main() → command_spec() → diagnostics.show_sing_box_config(raw) / lifecycle.stop()`. Семантика авторизации пути подтверждается [кодом rpcd](https://github.com/openwrt/rpcd/blob/master/file.c) и [аналогичным advisory OpenWrt](https://github.com/openwrt/luci/security/advisories/GHSA-vj96-f37g-37f6). В `Screamshow/forkop` ACL побайтно совпадает с этим снимком.

**Why existing tests don't catch it.** Frontend-тесты подменяют `executeShellCommand`; backend-тесты запускаются локально без rpcd-сессии с урезанной ролью.

**How to reproduce.** На тестовом OpenWrt создать делегированную read-only LuCI-сессию, проверить `ubus call session access` для `file /usr/bin/forkop exec`, затем вызвать только неразрушающее `show_sing_box_config raw` и сравнить с маскированным ответом. Проверку `stop` выполнять лишь на изолированном стенде.

**Recommended fix.** Убрать root-команды и чтение сырых конфигов из `read`. Разделить публичные диагностические методы и изменяющие операции на разные исполняемые точки/ACL; для диагностики возвращать только маскированные данные.

**Regression test.** Интеграционный тест настоящего rpcd: read-сессия не может вызвать `stop`, `full_uninstall` или получить raw-конфиг; write-сессия может выполнять только специально разрешённые действия.

### F-002 — Ошибка подготовки reload оставляет DPI-процессы выключенными

**Severity:** High
**Confidence:** Confirmed
**Area:** runtime / DPI / update
**Origin:** Inherited from upstream

**Files:** `forkop/files/usr/lib/service/lifecycle.uc:1570`, `:1577`, `:1591`, `:1607`, `:1616`, `:1082`, `:1721`.

**Problem.** Reload останавливает Zapret/Zapret2/ByeDPI до подготовки кандидата sing-box и nft. Любой возврат из `configure-service`, `singbox_prepare_config_stage`, `nft_candidate_begin` и иных последующих операций через `abort_reload(..., false)` удаляет лишь snapshot, не возвращая остановленные DPI-процессы. Старая nft/sing-box конфигурация при этом остаётся активной.

**Trigger.** Изменить правило DPI так, чтобы план потребовал `needs_*_restart`; после остановки DPI вызвать контролируемый сбой подготовки JSON или кандидата nft (например, отказ записи в staging-файл).

**Impact.** Маршруты на ByeDPI перестают работать. Для Zapret/NFQUEUE правило `queue ... bypass` из `nft/apply.uc:1038` пропускает трафик без обработки DPI, и сервис может перестать открываться. Ошибка reload видна, но прежний рабочий dataplane не восстановлен.

**Evidence.** `reload() → module_success(provider, stop-runtime) → ошибка staging → abort_reload(false) → return`; повторные `start-runtime` стоят только после успешного перехода на строках 1721–1726. Этот порядок присутствует и в `Screamshow/forkop`.

**Why existing tests don't catch it.** `service_reload_plan.sh` проверяет план, тесты владельцев DPI — отдельные команды процесса; сбой кандидата после фактического stop провайдера с наблюдением его восстановления не моделируется.

**How to reproduce.** На изолированном OpenWrt с работающим DPI-провайдером принудительно отказать staging-каталогу в записи, изменить DPI-настройку и вызвать reload; сопоставить exit code, процессы `nfqws`/`ciadpi`, старый nft и подключение к сервису.

**Recommended fix.** Готовить и валидировать кандидаты до остановки провайдера. После любой ошибки перехода восстанавливать старые процессы по снимку и проверять их работоспособность.

**Regression test.** Fault injection в каждую фазу после stop провайдера: при неудаче прежние процессы/очереди доступны, старый маршрут остаётся работоспособным.

### F-003 — reload сообщает успех, хотя DPI-провайдер не запустился

**Severity:** High
**Confidence:** Confirmed
**Area:** runtime / DPI / LuCI
**Origin:** Inherited from upstream

**Files:** `forkop/files/usr/lib/service/lifecycle.uc:1721`, `:1723`, `:1725`, `:1747`, `:1788`; `forkop/files/usr/lib/nft/apply.uc:1038`.

**Problem.** Все три `module_success(..., ["start-runtime"])` вызываются без проверки результата. После неудачи код продолжает DNS/cron, сохраняет reload-state и возвращает `0`.

**Trigger.** При изменении DPI-правила запустить reload с отсутствующим/неисполняемым `nfqws`, `nfqws2` или `ciadpi`, либо с занятым локальным портом ByeDPI.

**Impact.** LuCI и автоматизация видят успешное применение, но DPI-обход недоступен; NFQUEUE может обходиться без userspace-обработки. Следующий `on_config_change` способен пропустить повторный запуск, поскольку state уже записан.

**Evidence.** `reload() → start-runtime (boolean ignored) → write-captured-reload-state → return 0`. Результат повторного запуска отдельных провайдеров не входит в финальный статус.

**Why existing tests don't catch it.** Проверки CLI/плана не подменяют `start-runtime` кодом ошибки внутри полной функции reload.

**How to reproduce.** На стенде заблокировать исполняемый файл провайдера сразу после stop, вызвать reload и сравнить `echo $?`, `get_status` и наличие процесса/локального порта.

**Recommended fix.** Проверять запуск и readiness каждого требуемого провайдера до фиксации reload-state; при неудаче возвращать ошибку и восстанавливать предыдущую конфигурацию либо явно оставлять pending retry.

**Regression test.** Инъекция отказа каждого `start-runtime` с проверкой ненулевого статуса, отсутствия новой reload-state и корректного восстановления.

### F-004 — PID-файлы позволяют остановить другой процесс после reuse PID

**Severity:** Medium
**Confidence:** Confirmed
**Area:** runtime / process ownership
**Origin:** Inherited from upstream

**Files:** `forkop/files/usr/lib/singbox/dns_failover.uc:318`, `:325`, `:329`, `:347`; `forkop/files/usr/lib/singbox/priority.uc:432`, `:437`, `:454`; `forkop/files/usr/lib/providers/byedpi/runtime.uc:194`, `:207`, `:234`, `:242`.

**Problem.** DNS failover и Priority сохраняют только `$!` в PID-файле и считают любой существующий PID своим (`kill -0`), затем посылают `TERM`. ByeDPI повторно читает PID-файлы и посылает `KILL` после секунды без проверки exe, starttime и владельца. Это контрастирует с более строгой проверкой sing-box в `service/state.uc`.

**Trigger.** Worker аварийно завершается, оставив PID-файл; ядро повторно выдаёт PID другому процессу; следующий restart/reload вызывает `stop_runtime`.

**Impact.** Возможно завершение постороннего процесса роутера (в том числе `dnsmasq` или `uhttpd`). Вероятность зависит от PID reuse и времени между падением и restart; конкретный инцидент не наблюдался.

**Evidence.** `start_runtime() → echo $! > pidfile → worker dies → PID reused → process_running(kill -0) → kill PID`. Код этих модулей совпадает с `Screamshow/forkop`.

**Why existing tests don't catch it.** Тесты вызывают модули с временными PID и моками, не создают чужой процесс с переиспользованным PID/starttime.

**How to reproduce.** В отдельном namespace/контейнере записать PID другого долгоживущего процесса в тестовый `FORKOP_*_PID_FILE`, вызвать `stop-runtime` и проверить сигнал процессу. Не выполнять на роутере с реальным PID системной службы.

**Recommended fix.** Хранить PID вместе с `/proc/PID/stat` starttime и ожидаемой командой/исполняемым файлом; перед сигналом проверять обе характеристики. Для ByeDPI повторно подтверждать идентичность перед `KILL`.

**Regression test.** Проверка stale pidfile с живым чужим процессом; его состояние не меняется, PID-файл удаляется или помечается устаревшим.

### F-005 — validator принимает Bootstrap DNS hostname без безопасного resolver

**Severity:** Medium
**Confidence:** High
**Area:** DNS / config
**Origin:** Inherited from upstream

**Files:** `forkop/files/usr/lib/config/validator.uc:888`, `:939`; `forkop/files/usr/lib/singbox/dns.uc:128`, `:136`, `:157`, `:250`.

**Problem.** Валидатор принимает доменное имя в `bootstrap_dns_server`. Генератор `bootstrap_server()` создаёт UDP DNS server с `server=<hostname>`, но без `domain_resolver`. Для основного DNS hostname это поле добавляется; Bootstrap DNS не имеет независимого следующего resolver. По [документации sing-box для UDP DNS](https://sing-box.sagernet.org/configuration/dns/server/udp/) hostname сервера требует resolver. `route.default_domain_resolver` указывает на основной DNS или сам Bootstrap DNS, поэтому может образоваться зависимость по кругу.

**Trigger.** Указать hostname в `bootstrap_dns_server` и в основном `dns_server` (либо включить DNS detour, при котором `route.default_domain_resolver` указывает на Bootstrap). Значения проходят `validate-runtime`, но сгенерированный JSON не обеспечивает независимое bootstrap-разрешение имени.

**Impact.** Возможен отказ `sing-box check`/старта или `dns exchange deadline exceeded` при первом обращении к DNS. Конкретный исход зависит от версии sing-box; на устройстве не проверен.

**Evidence.** `validate_dns_settings() → dns_server_value_valid(hostname)=true → dns.config() → bootstrap_server(hostname)` без `domain_resolver`; основной `server_from_options()` явно добавляет `domain_resolver` при hostname.

**Why existing tests don't catch it.** `dns_failover.sh` проверяет только Bootstrap IP (`1.1.1.1`, `8.8.8.8`); при тестах генерации нет `sing-box check` с hostname Bootstrap.

**How to reproduce.** В тестовой UCI-фикстуре поставить Bootstrap hostname; выполнить `validate-runtime-fixture` и `generate-config-fixture`, затем `sing-box check -c <generated.json>` на поддерживаемой версии и проверить DNS-запрос после холодного запуска.

**Recommended fix.** Требовать IP-адреса для Bootstrap DNS либо вводить отдельный независимый IP-based resolver и исключать циклы при валидации.

**Regression test.** Валидатор и генератор для Bootstrap hostname с обязательным `sing-box check` и первым запросом без системного DNS.

### F-006 — транзакция перенастройки package feeds завершается до окончания install

**Severity:** Medium
**Confidence:** Confirmed
**Area:** installer / recovery
**Origin:** Inherited from upstream

**Files:** `install.sh:1657`, `:1723`, `:1757`, `:1787`, `:2810`, `:2822`, `:2832`, `:2844`.

**Problem.** После успешного `apk/opkg update` установщик вызывает `commit_package_mirror_transaction()`, что выключает rollback feed. Дальше ещё могут отказать получение release, скачивание пакетов, свободное место, миграция, установка UI и sing-box. `trap cleanup` вызывает `rollback_package_mirror`, но тот сразу возвращает `0` при `MIRROR_TRANSACTION_ACTIVE=0`.

**Trigger.** Запустить установку на чистом роутере; позволить перенастроить feeds и затем оборвать доступ к release JSON/asset либо получить ошибку пакета.

**Impact.** Forkop не установлен полностью, но системные OpenWrt feeds уже постоянно указывают на стороннее зеркало. Если оно недоступно позднее, обычные обновления пакетов также не работают. Создаются `.pre-forkop-mirror` копии, но автоматического отката после ошибки нет.

**Evidence.** `main() → configure_package_mirror() → commit_package_mirror_transaction() → fail(later) → cleanup() → rollback_package_mirror()` пропускает восстановление.

**Why existing tests don't catch it.** `installer_feed_transaction.sh` проверяет откат ошибки внутри настройки feed; отказ в более поздней фазе после commit не проверяется.

**How to reproduce.** В тестовом rootfs подменить package manager и `http_get`: успешный update feed, затем неудача `resolve_forkop_release`; сравнить feed до/после выхода установщика.

**Recommended fix.** Держать transaction активной до конца install или явно восстанавливать прежние feeds на ошибках последующих фаз. Сохранить отдельное сознательное решение о постоянном использовании зеркала после успешного завершения.

**Regression test.** Fault injection на каждом значимом шаге после настройки feed с проверкой исходных файлов `/etc/apk/*`/`/etc/opkg/distfeeds.conf` при ошибке.

### F-007 — IPK обновляется по пакетам без отката согласованной версии

**Severity:** Medium
**Confidence:** Confirmed
**Area:** updater / LuCI / package lifecycle
**Origin:** Inherited from upstream

**Files:** `forkop/files/usr/lib/components/action.uc:1973`, `:1997`, `:2002`, `:2006`; `install.sh:2745`, `:2795`, `:2844`.

**Problem.** При `opkg` встроенный updater ставит новую LuCI app, затем i18n, затем backend. Ошибка на втором или третьем шаге вызывает `action_fail`, но предыдущие пакеты не восстанавливаются. Самостоятельный `install.sh` использует обратный порядок, но также не откатывает уже установленные пакеты. На APK файлы передаются одной командой, поэтому сценарий относится прежде всего к OpenWrt 24.10/IPK.

**Trigger.** Дать успешно установить новый `luci-app-forkop_*.ipk`, затем получить ошибку установки backend (нехватка overlay/ошибка maintainer script).

**Impact.** UI новой версии вызывает команды или ждёт ответов старого backend, возможны сломанные действия и неполное восстановление сервиса. В `install.sh` восстановление состояния службы на строках 2151–2160 не является откатом версии пакета.

**Evidence.** `install_forkop() → pkg_install_files(app) → pkg_install_files(i18n) → pkg_install_files(backend)` с немедленным `action_fail` и без сохранения прежних IPK.

**Why existing tests don't catch it.** Тесты проверяют порядок/контракты вызовов, не состояние установленного набора пакетов при отказе второго/третьего opkg.

**How to reproduce.** В OpenWrt 24.10 rootfs использовать mock `opkg`, который принимает app и отвергает backend; сравнить версии установленных пакетов и доступность UI/API после выхода.

**Recommended fix.** Готовить откатный набор прежних IPK и применять как единую управляемую операцию; как минимум восстанавливать app/i18n при неудаче backend и проверять итоговую согласованность версий.

**Regression test.** Поочерёдный отказ каждого `opkg install` с проверкой версий всех трёх пакетов и статуса Forkop.

### F-008 — встроенный updater устанавливает локальные пакеты без проверки digest

**Severity:** Medium
**Confidence:** Confirmed
**Area:** updater / supply chain
**Origin:** Inherited from upstream

**Files:** `forkop/files/usr/lib/components/action.uc:404`, `:624`, `:635`, `:1938`, `:1973`, `:1976`, `:1989`; `install.sh:2728`, `:2735`.

**Problem.** Встроенный `install_forkop()` берёт из release metadata только имена и URL, проверяет скачанные файлы на ненулевой размер и устанавливает их. Для APK используется `apk add --allow-untrusted`, для OPKG — локальные IPK. В отличие от отдельного `install.sh`, SHA-256 asset не проверяется. HTTPS защищает транспорт до выбранного host, но не обнаруживает замену артефакта после получения metadata или компрометацию зеркала/asset endpoint.

**Trigger.** Между получением `latest.json` и скачиванием пакетов зеркало отдаёт другой непустой валидный пакет по тому же URL либо release endpoint скомпрометирован.

**Impact.** Возможна установка неожиданного пакета с root maintainer scripts. Дефект не является доказательством текущей компрометации зеркала; контроль этого endpoint уже является сильной предпосылкой атаки.

**Evidence.** `resolve_forkop_release()` не сохраняет digest → `download_with_retry()` проверяет лишь `file_nonempty` → `pkg_install_files_command()` ставит локальные файлы с `--allow-untrusted` для APK. В `install.sh` рядом существует `verify_download_sha256`.

**Why existing tests don't catch it.** Тесты updater мокируют успешную загрузку и вызов package manager, не подменяют содержимое asset между metadata и установкой.

**How to reproduce.** На стенде подать корректный release JSON с известным SHA-256, затем по URL вернуть другой валидный APK/IPK; зафиксировать отсутствие отказа до package manager. Не запускать неподписанный пакет на рабочем роутере.

**Recommended fix.** Перед установкой проверять SHA-256 каждого asset; для APK не использовать `--allow-untrusted` без независимой доверенной подписи. Digest из того же скомпрометированного JSON не решит проблему доверия к самому источнику, поэтому отдельно закрепить доверенный ключ/подпись release.

**Regression test.** Проверка несовпадающего digest и неподписанного APK: package manager не вызывается.

### F-009 — полный `fw4 flush` оставляет sing-box работающим без nft-перехвата

**Severity:** Medium
**Confidence:** High
**Area:** networking / recovery
**Origin:** Inherited from upstream

**Files:** `forkop/files/usr/lib/nft/apply.uc:862`, `:881`, `:892`, `:912`; `forkop/files/usr/lib/service/initd.uc:772`, `:779`, `:780`; `forkop/files/usr/lib/service/lifecycle.uc:1480`.

**Problem.** Обычный `fw4 reload` затрагивает только `inet fw4`, но административный `fw4 flush` удаляет все nft-таблицы, в том числе `ForkopTable` ([исходник fw4](https://github.com/openwrt/firewall4/blob/master/root/sbin/fw4)). Forkop не подписан на событие полного сброса nft; его trigger plan включает UCI и interface up. Уже работающий sing-box остаётся живым, но новые пакеты больше не получают mark/TPROXY. Следующий явный reload обнаружит неполный runtime и восстановит его, но до этого автоматического восстановления нет.

**Trigger.** `fw4 flush` либо сторонний пакет/скрипт вызывает `nft flush ruleset` при работающем Forkop; затем клиент создаёт новое соединение к домену, который раньше попадал в прокси.

**Impact.** Соединение может пройти обычным WAN напрямую. Это сценарий полного сброса ruleset, а не штатного firewall reload; на реальном роутере не воспроизведён.

**Evidence.** `nft_create_table(ForkopTable) → fw4 flush deletes every table → no mangle mark / TPROXY → trigger-plan has no firewall/ruleset event`; проверка `forkop-running` вызывается при следующем reload, а не непрерывно.

**Why existing tests don't catch it.** `nft_atomic_apply.sh` моделирует candidate transaction; внешний `fw4 flush` и новые клиентские пакеты не моделируются.

**How to reproduce.** Только на изолированном роутере: зафиксировать `nft list table inet ForkopTable` и внешний IP клиента через прокси; выполнить `fw4 flush`, создать новое клиентское соединение и проверить nft/публичный IP; затем вручную `/etc/init.d/forkop reload` для восстановления.

**Recommended fix.** Обнаруживать исчезновение таблицы и восстанавливать сервис; до восстановления предотвращать direct-трафик для политики, требующей обязательного прокси. Не привязывать такой вывод к обычному `fw4 reload`.

**Regression test.** Интеграционный OpenWrt тест `fw4 flush`/внешнего `nft flush ruleset` с новой TCP/UDP сессией и измерением маршрута до и после восстановления.

### F-010 — при выбранной загрузке компонентов через прокси updater повторяет запрос напрямую

**Severity:** Medium
**Confidence:** Confirmed
**Area:** updater / network privacy
**Origin:** Inherited from upstream

**Files:** `forkop/files/etc/config/forkop:42`, `:44`; `forkop/files/usr/lib/singbox/runtime.uc:511`, `:520`; `forkop/files/usr/lib/components/action.uc:560`, `:597`, `:603`, `:611`, `:624`, `:630`.

**Problem.** Настройка `download_components_via_proxy`/`download_components_via_proxy_section` выбирает сервисный прокси, но `http_get()` и `download_file_once()` после любой ошибки прокси вызывают тот же URL без прокси. Если sing-box не работает, `service_proxy_address()` сразу возвращает пустую строку и первая попытка тоже идёт напрямую. Отдельный загрузчик подписок такого fallback не имеет.

**Trigger.** Включить загрузку компонентов через выбранную секцию; сделать локальный HTTP proxy недоступным или остановить sing-box; проверить обновление Forkop/sing-box/Zapret.

**Impact.** IP роутера, факт обращения к release host и URL component metadata/asset видны прямому WAN, несмотря на выбор «Download components through a section». Если прямой маршрут блокирован, обновление всё равно не завершится. Лог отмечает direct retry уже после попытки.

**Evidence.** `service_proxy_address() → http_get_once(url, proxy) fails → http_get_once(url, "")`; аналогично `download_file_once()`. Этот fallback есть и в `Screamshow/forkop`.

**Why existing tests don't catch it.** Тесты компонента проверяют успешные/неуспешные действия, но не сеть и источник исходящего соединения после сбоя proxy.

**How to reproduce.** На тестовом роутере указать proxy section и endpoint обновления под своим контролем; заблокировать локальный proxy; запустить `check_update` и увидеть прямое соединение к endpoint через WAN в `tcpdump`.

**Recommended fix.** Явно определить режим: при выбранной секции прекращать загрузку при отказе прокси либо показывать отдельную опцию/подтверждение «разрешить прямой fallback». Bootstrap обновления без работающего sing-box должен иметь отдельное понятное правило.

**Regression test.** Mock curl с проваленной proxy-попыткой: в строгом режиме второй вызов без `-x` отсутствует; интеграционно подтвердить отсутствие WAN-пакетов к endpoint.

## Architecture risks

Три независимые единицы состояния — UCI/JSON sing-box, nft и userspace DPI — обновляются не одной транзакцией. Кандидат nft и guard защищают часть перехода sing-box, но F-002/F-003 показывают, что DPI-процессы не включены в тот же commit/rollback. DNS зависит от корректного bootstrap даже до появления рабочего прокси (F-005). Установщик и updater обслуживают несколько пакетов/feeds и не обеспечивают согласованного отката всех компонентов (F-006/F-007). Зеркало является доверенной частью цепочки поставки (F-008).

## Race conditions

| Race / TOCTOU | Доказанный переход | Последствие | Finding |
| --- | --- | --- | --- |
| Worker завершился, PID переиспользован до stop | PID-файл → `kill -0` → `kill` | Сигнал чужому процессу | F-004 |
| DPI stop произошёл до ошибки подготовки кандидата | stop → ошибка staging → `abort_reload(false)` | Прежняя маршрутизация с выключенным DPI | F-002 |
| DPI start вернул ошибку до записи reload-state | return игнорируется → snapshot записан | Ложный успех и пропуск повторного запуска | F-003 |
| Release asset изменился после чтения metadata | URL получен → непустой файл скачан → локальная установка | Нет проверки содержимого перед установкой | F-008 |
| Полный nft flush произошёл между проверками состояния | таблица удалена, sing-box продолжает работать | Новые потоки без mark | F-009 |

Для одновременных LuCI RPC, двойного restart, PID sing-box и stale procd статуса изучены блокировки `service/initd.uc`, `service/state.uc` и тесты `start_reload_serialization.sh`, `singbox_stale_procd_pid.sh`; отдельный подтверждённый дефект из этого пути не получен. Это не доказывает отсутствия race на устройстве.

## Traffic leak scenarios

* **F-009:** только полный сброс ruleset/таблицы, после которого новые клиентские потоки могут уйти напрямую до явного восстановления. Штатный `fw4 reload` сюда не относится.
* **F-002/F-003:** правила NFQUEUE используют `bypass`; при выключенном `nfqws`/`nfqws2` DPI-обработка не производится. Это обход DPI, а не обязательно обход VPN-прокси.
* **F-010:** сетевые запросы обновления компонентов повторяются через прямой WAN после сбоя выбранного proxy; это утечка адреса/URL обновления, а не обход клиентской TPROXY-маршрутизации.
* Прямой доступ для локальных/private сетей и исключённых устройств задан явно в `nft/apply.uc:892-919`; сам по себе он не является утечкой. Source-интерфейсы по умолчанию `br-lan` (`nft/apply.uc:938`): трафик других интерфейсов, включая VPN ingress, требует отдельного включения и проверяется по их UCI-настройкам.

## DNS failure scenarios

* **F-005:** hostname Bootstrap DNS принят validator, но не имеет независимого resolver; риск startup failure и `dns exchange deadline exceeded`.
* При нескольких main/bootstrap серверах `singbox/dns_failover.uc:252-315` опрашивает кандидатов и выбирает другой сервер после порога; тест `dns_failover.sh` проверяет выбор на фикстурах. При единственном сервере failover-worker сознательно не запускается, поэтому восстановление зависит от возвращения того же DNS. Само по себе это не баг.
* `dns/apply.uc:182-194` переводит dnsmasq на sing-box и отключает внешний resolv; это предотвращает прямой системный fallback, но при падении DNS sing-box может сделать клиентский DNS недоступным. Проверка DNS утечки и NXDOMAIN/SERVFAIL на физическом роутере остаётся необходимой.

## Upgrade/install failure matrix

| Stage | Failure | Current behaviour | Recovery | Risk |
| --- | --- | --- | --- | --- |
| Переключение feed до commit | `apk/opkg update` отказал | `rollback_package_mirror()` восстанавливает копии | Автоматический откат | Низкий в этой фазе |
| После commit feed | release/download/install отказал | Feed остаётся на зеркале | Ручное восстановление `.pre-forkop-mirror` | F-006 |
| IPK LuCI app → backend | второй/третий пакет отказал | Уже поставленные IPK остаются новыми | Ручное восстановление согласованного набора | F-007 |
| Обновление Forkop в UI | asset подменён между metadata и install | Проверяется только непустой файл | Отказ зависит от package manager; валидный чужой пакет может установиться | F-008 |
| Загрузка обновления через proxy section | локальный proxy отказал | Updater повторяет metadata/asset запрос напрямую | Повторить с работающим proxy или запретить fallback | F-010 |
| Reload DPI | ошибка после stop или при повторном start | Провайдер остаётся остановленным / статус может быть успешным | Ручной restart после устранения причины | F-002, F-003 |
| List/subscription update | сеть или запись отказали | Кандидат/кэш во многих путях сохраняет предыдущую генерацию | Повторный update; проверить marker/runtime | Отдельного доказанного дефекта не найдено |
| Reboot во время update | процесс прерван | Состояние пакетов/кэша зависит от фазы | Проверить package manager, manifest и сервис после загрузки | Нужен router test |
| Full uninstall | ошибка удаления пакета | Скрипт ведёт status, но не возвращает все уже удалённые компоненты | Восстановление из резервной копии | Ожидаемая необратимость удаления |

## Missing tests

1. Настоящий rpcd с read-only и write LuCI-сессиями для F-001, включая отсутствие raw-секретов.
2. Полный reload с инъекцией ошибок после `stop-runtime` и на каждом `start-runtime` для F-002/F-003.
3. Stale/reused PID в отдельном PID namespace для F-004.
4. Валидатор + генератор + `sing-box check` + холодный DNS-запрос для Bootstrap hostname (F-005).
5. Тест отказа на каждом этапе после `commit_package_mirror_transaction` и каждом `opkg install` (F-006/F-007).
6. Подмена валидным пакетом при несовпадающем digest до package manager (F-008).
7. Router integration: обычный `fw4 reload` и отдельный `fw4 flush` с проверкой `nft list ruleset`, `ip rule`, новых TCP/UDP потоков и внешнего IP (F-009).
8. Отказ выбранного proxy при component update с захватом WAN-пакетов и проверкой отсутствия direct fallback (F-010).
9. Реальные WAN/PPPoE/mwan3/WireGuard, IPv6/AAAA, FakeIP, DNS NXDOMAIN/SERVFAIL/timeout и короткие обрывы: текущие тесты преимущественно проверяют ucode-фикстуры/моки, а не трафик с клиентского устройства.

## False positives investigated

* **«Обычный firewall reload удаляет ForkopTable».** Не подтверждено: Forkop создаёт отдельную `inet ForkopTable` (`nft/apply.uc:862`), а шаблон firewall4 делает `flush table inet fw4` ([исходник](https://github.com/openwrt/firewall4/blob/master/root/usr/share/firewall4/templates/ruleset.uc)). `fw4 flush` принципиально отличается и вынесен в F-009.
* **«Любой reload сначала удаляет активную nft-таблицу».** Не подтверждено: `nft/apply.uc:1592-1617` валидирует candidate и применяет `nft -f`; тест `nft_atomic_apply.sh` проверяет отказ check/apply с сохранением активной политики. Межкомпонентный DPI transition остаётся отдельным дефектом.
* **«Запуск Forkop может убить чужой sing-box».** Основной путь `service/state.uc:603-636`, `:668-771` проверяет procd PID, exe, starttime и количество sing-box процессов, тесты покрывают stale procd PID. Дефект F-004 относится к другим worker-процессам.
* **«`innerHTML` в редакторе LuCI очевидно даёт XSS».** `section.js:4477-4508` экранирует каждый фрагмент пользовательского текста до вставки. Само наличие `innerHTML` здесь недостаточно для finding.
* **«Любая ошибка загрузки списка сразу заменяет рабочую генерацию».** `components/updates.uc` использует preflight и staged/cache поколения; `tests/list_transaction_failures.sh` и `list_update_final_reload.sh` проверяют отказные ветки. Аппаратного подтверждения на заполненном overlay нет.

## Top priority fixes

1. **Перед следующим релизом:** F-001, F-002, F-003. Это граница полномочий и неконсистентное восстановление сервиса с ложным успехом.
2. **Следом:** F-005, F-007, F-008, F-009, F-010. Они затрагивают работоспособность DNS, согласованность обновлений, доверие к пакетам, поведение при полном сбросе nft и прямые запросы обновления.
3. **Можно отложить до следующего цикла после стендового воспроизведения:** F-004, F-006. Для F-004 нужен контролируемый PID reuse; для F-006 — решение о транзакционной политике package feeds.
