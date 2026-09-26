# Validated audit fixes

## F-001

**Root cause**

`rpcd` разрешал read-сессии исполнение всего `/usr/bin/forkop`, а также прямое чтение sing-box JSON, section cache и всего UCI-пакета `forkop`. Path-wide `exec` разрешал любые аргументы, включая управляющие команды и `raw`.

**Fix**

ACL `read` теперь содержит только явные диагностические command-line grants. Полный CLI, init script, raw JSON/cache и UCI перенесены в `write`. Для read-only dashboard добавлены отдельные команды, отдающие только структурные UCI-поля и необходимые URLTest-метаданные; frontend использует очищенные секции при отказе UCI-доступа и больше не читает raw sing-box JSON.

**Invariant preserved**

Read-only пользователь видит статус и dashboard без возможности управления сервисом или чтения raw secrets. Пользователь с `write` сохраняет прежние настройки и управление. Sing-box ownership и dataplane не менялись.

**Tests added**

`tests/acl_boundary.sh` проверяет запрет опасных команд/raw files и отсутствие секретов в новых read endpoint; `getConfigSections.test.ts` проверяет UCI fallback; обновлён `getDashboardSections.test.ts`.

**Tests executed**

Backend suite в WSL Ubuntu 24.04: 114 passed, 1 failed (`tests/list_cache.sh` из-за известного ограничения WSL `/tmp` на фиктивном пороге `999999999999` байт). Frontend: 46 файлов, 514 тестов passed; ESLint, `tsc --noEmit`, `npm run build` passed. `ucode -c` изменённого backend-файла и `git diff --check` passed.

**Remaining runtime validation**

На тестовом OpenWrt проверить настоящую read-only rpcd-сессию через `ubus call session access` и LuCI dashboard; подтвердить отказ `stop`, `full_uninstall`, raw config/UCI и работу статусных команд. Проверить, что URLTest display metadata на устройстве не раскрывает секретные параметры.

**Commit**

`33c070a2c1c640fd860391ecd2f5b35e4d957099`

## F-002 + F-003

**Root cause**

Reload останавливал Zapret/Zapret2/ByeDPI до подготовки sing-box и nft, а ошибки подготовки не возвращали прежние процессы. Последующие вызовы `start-runtime` игнорировали status; reload мог записать новый state при неработающем DPI.

**Fix**

Перед первым stop снимаются фактические аргументы прежних supervisor-процессов и, когда меняется таблица, её nft-снимок. Sing-box staging и nft candidate подготавливаются до DPI stop. Во время переключения отдельный nft output guard блокирует marked NFQUEUE traffic. Все три `start-runtime` проверяются, включая наличие дочернего процесса. При отказе выполняется возврат прежних процессов, таблицы и, если был переход, sing-box config; reload возвращает ошибку. Новый reload state записывается только после успешного запуска DPI.

**Invariant preserved**

Отказ подготовки не останавливает прежний DPI. Отказ stop/start или nft commit до записи state ведёт к восстановлению прежнего DPI; при неудаче отката временный guard остаётся для fail-closed поведения. Staged sing-box config, nft candidate, sing-box ownership gate и отдельная `ForkopTable` сохранены.

**Tests added**

`tests/dpi_runtime_snapshot.sh` проверяет реальный снимок и восстановление supervisor и child PID. `tests/dpi_reload_faults.sh` инжектирует отказ после stop и отказ запуска каждого из Zapret, Zapret2 и ByeDPI, проверяет ненулевой status, вызовы восстановления и порядок до записи state. `tests/dpi_transition_guard.sh` проверяет guard для обоих NFQUEUE marks. `tests/service_start_trap.sh` уточнён для прежней общесервисной очистки при ошибке dnsmasq.

**Tests executed**

Целевые тесты прошли. Backend suite в WSL Ubuntu 24.04: 117 passed, 1 failed (`tests/list_cache.sh`, прежнее ограничение WSL `/tmp` при пороге `999999999999` байт). Frontend: 46 файлов, 514 тестов passed. `ucode -c` изменённых модулей и `git diff --check` прошли.

**Remaining runtime validation**

На OpenWrt 24.10 и 25.12+ проверить `nft -c -f` сохранённой таблицы и переходы с изменением числа DPI-правил, включая провал каждого процесса и rollback после nft commit; сверить marks/queues и packet capture на отсутствие bypass. После дополнительного исправления отказ dnsmasq требует живой проверки восстановления прежнего `/etc/config/dhcp`, перезапуска dnsmasq и DPI. Если сам возврат DNS не сработает, остаётся fail-safe остановка частично применённого runtime; абсолютное восстановление при системной ошибке dnsmasq не заявляется.

**Commit**

`f00735f262d1432234e2fdf495915837bc64e4f5`

**Adversarial review correction**

Отдельный review обнаружил, что после переключения DPI отказ dnsmasq вызывал общесервисную очистку без возврата прежних процессов. Теперь перед DNS apply сохраняется конфигурация `dhcp`; при ошибке или последующем отказе до commit она возвращается и dnsmasq перезапускается до восстановления прежнего DPI. Если возврат DNS невозможен, остаётся прежняя fail-safe очистка. `tests/dns_reload_snapshot.sh` проверяет снимок и повтор после отказа перезапуска; `tests/dpi_reload_faults.sh` проверяет успешный DNS rollback и его fail-safe ветку. Адресные тесты, `ucode -c`, backend suite (121 passed, 1 WSL-specific failed) прошли. Коммит: `ec336d1f7b709723878edc94f6ca6475c7aafc97`.

## F-004

**Root cause**

DNS failover, Priority, ByeDPI и общий NFQUEUE runtime использовали PID-файл как единственное доказательство ownership. `kill -0` подтверждал только существование номера; stale PID мог привести к `TERM` или `KILL` чужому процессу.

**Fix**

Новые pidfile содержат PID и starttime из `/proc/<pid>/stat`. Перед каждым сигналом проверяются сохранённый starttime, `/proc/<pid>/exe`, argv и повторный starttime. `KILL` без сохранённого starttime запрещён. Legacy supervisor/worker PID-only допускают `TERM` только после проверки executable и argv; legacy child получает starttime лишь после проверки, что он является потомком соответствующего Forkop supervisor. Sing-box ownership код не изменён.

**Invariant preserved**

Чужой процесс со случайно совпавшим PID не получает сигнал. Штатные Forkop workers и DPI children по-прежнему завершаются, включая старые pidfile при доказанной цепочке родителей. При недоказанном ownership сигнал пропускается.

**Tests added**

`tests/process_identity.sh` проверяет двухстрочный pidfile, чужой PID, stale starttime, запрет `KILL` для legacy PID-only, успешные `TERM`/`KILL` собственного worker и миграцию legacy child только при родстве с supervisor. `tests/foreign_pid_stop.sh` вызывает production `stop-runtime` DNS failover, Priority, ByeDPI и Zapret2 с PID безвредного `sleep` и проверяет, что процесс жив.

**Tests executed**

Адресные тесты и `ucode -c` изменённых модулей прошли. Backend suite в WSL Ubuntu 24.04: 119 passed, 1 failed (`tests/list_cache.sh`, прежнее ограничение WSL `/tmp` при фиктивном пороге `999999999999` байт). Frontend: 46 файлов, 514 тестов passed. `git diff --check` passed.

**Remaining runtime validation**

На OpenWrt 24.10 и 25.12+ проверить запуск/остановку реальных nfqws, nfqws2, ciadpi, Priority и DNS failover, включая respawn child и обновление пакетов с удалённым executable. PID/starttime/argv уменьшают риск reuse, но между последней проверкой `/proc` и `kill` остаётся узкое окно; pidfd в целевых OpenWrt/BusyBox здесь не используется.

**Commit**

`6610a3714c3232291df687a9980defca3471dca9`

## F-005

**Root cause**

Валидатор принимал hostname Bootstrap DNS через общий путь с основным DNS, тогда как генератор создавал UDP bootstrap без независимого `domain_resolver`. По [документации sing-box UDP DNS](https://sing-box.sagernet.org/configuration/dns/server/udp/) hostname в поле `server` требует `domain_resolver`.

**Fix**

Выбран IP-only контракт Bootstrap DNS: backend и LuCI отвергают hostname и URL с понятной ошибкой, сохраняя IPv4/IPv6 с необязательным портом. Основной DNS по-прежнему может быть hostname и использует IP bootstrap как resolver. Подсказка LuCI уточнена; frontend bundle пересобран.

**Invariant preserved**

Bootstrap не зависит от DNS-контура, который он должен запускать. DNS failover продолжает переключать IP bootstrap servers; detour и hostname основного DNS не менялись.

**Tests added**

`tests/config_validator_runtime.sh` отвергает hostname/URL bootstrap и принимает IPv6 с портом. `tests/dns_failover.sh` проверяет generated config активного и health bootstrap, отсутствие у них рекурсивного resolver и содержит условный `sing-box check -c`. `validateDns.test.js` проверяет LuCI-валидатор на IP, hostname, URL и портах.

**Tests executed**

Целевые backend/frontend тесты прошли. Backend suite в WSL Ubuntu 24.04: 119 passed, 1 failed (`tests/list_cache.sh`, прежнее ограничение WSL `/tmp` при фиктивном пороге `999999999999` байт). Frontend: 46 файлов, 523 теста passed; ESLint, `npm run build`, `node --check settings.js`, `ucode -c validator.uc` и `git diff --check` passed. Локального `sing-box` binary нет, поэтому условный `sing-box check` не выполнялся.

**Remaining runtime validation**

На OpenWrt 24.10 и 25.12+ выполнить `sing-box check -c` с generated config и проверить разрешение hostname основного DNS после отключения системного resolver; убедиться, что hostname Bootstrap DNS отвергается до изменения runtime и ошибка видна в LuCI.

**Commit**

`7a2375da622c008f132b0cff0c39015f3e5dfd47`

## F-007

**Root cause**

OPKG updater устанавливал LuCI app, i18n и backend отдельными командами. После первого успешного шага отказ следующего вызывал `action_fail()` без проверки установленных версий и без возврата прежних пакетов. Исходники [OPKG](https://raw.githubusercontent.com/openwrt/opkg-lede/master/libopkg/opkg_cmd.c) подтверждают, что и один вызов с несколькими `.ipk` последовательно вызывает установку каждого аргумента; это не атомарная транзакция.

**Fix**

Перед OPKG upgrade проверяется согласованность установленного набора, загружаются пакеты прежнего релиза в постоянный закрытый каталог, выполняется `opkg --noaction` для нового набора и для отката. Маркер возврата записывается до первого изменения. Backend обновляется первым, затем LuCI app и установленный i18n. После каждого отказа либо несовпадения итоговых версий весь старый набор повторно устанавливается в обратном порядке с `--force-reinstall`; проверяется фактическая версия каждого пакета. Если откат не завершился, архив и маркер сохраняются, а следующая попытка установки сначала повторяет возврат. На чистой системе родительский каталог архива создаётся до OPKG-команд. APK-путь не изменён.

**Invariant preserved**

Управляемая ошибка одного пакетного шага не объявляется успешным обновлением и не оставляет частично установленный release set без попытки возврата. Если старый набор нельзя подготовить, обновление не начинается. При отказе самого отката сохранены пакеты и явный путь восстановления. Mirror feed policy, direct fallback, cache fallback, sing-box ownership и отдельная `ForkopTable` не менялись.

**Tests added**

`tests/forkop_opkg_set.sh` исполняет production функции с инъекцией отказа backend, app, i18n и несовпадения версии после последнего шага; проверяет полный возврат, вариант без i18n, отказ при изначально смешанном наборе, сохранение архива после ошибки отката и повторное восстановление без сети.

**Tests executed**

Адресный тест, `ucode -c`, проверка forward references и `git diff --check` прошли. Полный backend suite в WSL Ubuntu 24.04: 121 passed, 1 failed (`tests/list_cache.sh` на фиктивном пороге `/tmp` 999999999999 байт). При предыдущем прогоне watchdog-тест `tests/installer_owner.sh` завершился по времени; отдельный повтор прошёл. Frontend: 46 файлов, 523 теста passed; lint и build прошли.

**Remaining runtime validation**

На OpenWrt 24.10 с настоящим OPKG проверить `--noaction`, `--force-reinstall`, пакетные postinst и отказ после каждого шага, затем повтор обновления после перезагрузки. Архив прежних пакетов требует свободного места в overlay. Отсутствующий прежний релиз или недоступный GitHub API теперь безопасно блокируют автоматическое обновление; нужен ручной путь для локальных/dev сборок. При невосстановимом отказе самого OPKG код сохраняет архив, но не может гарантировать согласованность файлов до успешного повторного отката. Автоматическое восстановление при загрузке устройства пока не реализовано; повтор запуска обновления сначала обрабатывает маркер.

**Commit**

`d58697f2f01c33094b2ff289ea839d6c7765b00f`

Дополнительный коммит после review: `1996696abb43e53d5523106e792da6b33fa3713e`.

## Финальная проверка собственного diff

- **F-001:** read-only dashboard и статусы сохранены; право на полный CLI, service operations и raw secrets осталось только у write. Новых привилегий не добавлено. На OpenWrt требуется проверка реальных `rpcd` ACL, включая маскирование логов и метаданных.
- **F-002/F-003:** подготовка sing-box/nft до DPI stop и rollback при отказе проверены тестами. Обнаруженный DNS post-commit пробел исправлен отдельным коммитом. Guard и отдельная nft table сохранены; при отказе восстановления DNS применяется fail-safe очистка. Packet capture на OpenWrt нужен для подтверждения отсутствия traffic leak.
- **F-004:** PID, starttime, executable и argv проверяются перед TERM/KILL; legacy child допускается только после проверки родства. Чужой процесс в тесте не получает сигнал. Узкое окно между последней проверкой `/proc` и сигналом остаётся свойством интерфейса BusyBox без pidfd.
- **F-005:** IP-only Bootstrap DNS согласован в backend и LuCI; основной DNS, failover и detour не менялись. Отказ hostname происходит до генерации runtime. На устройстве ещё требуется `sing-box check`.
- **F-007:** OPKG не предоставляет атомарный rollback; предварительный архив и повторная установка устраняют проверенные управляемые частичные отказы. Отказ подготовки блокирует обновление, что меняет поведение локальных/dev установок. Маркер и архив снижают риск после power loss, но не выполняют восстановление сами при загрузке. Это оставшееся ограничение требует проверки на устройстве и решения о startup recovery.

В изменениях нет F-006/F-008/F-009/F-010, переноса `ForkopTable` в fw4, изменения mirror feed policy, direct fallback, cache fallback, sing-box ownership или ослабления staged JSON/nft transition. Сборка OpenWrt 24.10 и 25.12+ и реальные пакетные/postinst переходы локально не выполнялись.
