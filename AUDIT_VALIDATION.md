# Forkop — независимая валидация технического аудита

Аудируемый снимок: `slayer326/forkop` `bbd7a2d8bea42161f23207cdaa273579cc398cc8` (25.09.2026). Исходные гипотезы: [AUDIT.md](AUDIT.md). Проверены production code, тесты, README, release/upstream notes, `git blame` и история доступного репозитория. Совпадение с Podkop или Screamshow устанавливает происхождение, но не доказывает корректность. На OpenWrt, с настоящими rpcd/procd/nft и сетью, испытаний этого этапа не было. Severity означает приоритет исправления в заявленном сценарии, а не частоту инцидентов.

## Audit Validation Summary

| Finding | Original Severity | Classification | Final Severity | Confidence |
| ------- | ----------------- | -------------- | -------------- | ---------- |
| F-001 | High | CONFIRMED_DEFECT | High | High |
| F-002 | High | CONFIRMED_DEFECT | High | High |
| F-003 | High | CONFIRMED_DEFECT | High | High |
| F-004 | Medium | CONFIRMED_DEFECT | Medium | High |
| F-005 | Medium | INCOMPLETE_FEATURE | Medium | High |
| F-006 | Medium | DELIBERATE_TRADEOFF | Low | High |
| F-007 | Medium | CONFIRMED_DEFECT | Medium | High |
| F-008 | Medium | TECHNICAL_DEBT | Low | Medium |
| F-009 | Medium | NEEDS_RUNTIME_VALIDATION | Low | Medium |
| F-010 | Medium | DELIBERATE_TRADEOFF | Medium | High |

- Confirmed defects: 5
- Intentional features: 0
- Deliberate trade-offs: 2
- Compatibility behaviour: 0
- Defensive behaviour: 0
- Documentation mismatches: 0
- Incomplete features: 1
- Technical debt: 1
- False positives: 0
- Needs runtime validation: 1

### F-001 — LuCI `read` и привилегированный CLI

**Original conclusion:** read ACL даёт запуск опасных CLI-команд и чтение сырых секретов. **Original severity:** High. **Validation classification:** `CONFIRMED_DEFECT`. **Final severity:** High. **Confidence:** High.

#### Observed behaviour

`luci-app-forkop/root/usr/share/rpcd/acl.d/luci-app-forkop.json:4-47` помещает `/usr/bin/forkop` и init script `exec`, а также сырые sing-box JSON `read`, в роль `read`. `forkop/files/usr/bin/forkop:124-190` содержит изменяющие и диагностические команды, включая raw. В [rpcd `file.c`](https://github.com/openwrt/rpcd/blob/master/file.c) проверка полного командного ряда с аргументами выполняется **только когда** ACL не разрешила сам executable (`rpc_file_exec_run`, условие `if (!rpc_file_access(... executable, "exec"))`). Значит возможность rpcd ограничивать аргументы не защищает этот path-wide grant. Реальную делегированную сессию мы не запускали.

#### Design intent

`git blame`: право на CLI появилось при rebrand `9b0cbeb5` 11.07.2026 и было перенесено из LuCI Podkop; raw file reads добавлены `6a63effb7` 25.08.2026. Название ACL и frontend-вызовы указывают на желание дать интерфейсу диагностику и управление из одной точки. Доказательств осознанного разрешения `stop/full_uninstall` именно read-only роли нет.

#### Historical reason

Общий CLI и ACL были перенесены при rebrand; причина размещения полного `exec` именно в `read` — **Unknown**. В `Screamshow/forkop` та же гранулярность; это не независимое подтверждение безопасности.

#### Arguments that this is intentional/correct

LuCI-клиенту требуются status/diagnostic вызовы; у обычной root-сессии разграничение read/write не проявляется. `rpcd` теоретически поддерживает ACL по полной командной строке.

#### Arguments that this is defective

Path-wide grant отключает проверку аргументов; одна и та же read-сессия может обратиться к `stop` и raw-конфигу. Это нарушение заявленной границы прав вне зависимости от того, вызывает ли UI эти команды. Прямой `file.read` JSON отдельно обходит маскирование диагностики.

#### Invariant analysis

Нарушена граница полномочий; доступность и секретность конфигурации зависят от read-only делегирования. Ownership-защита sing-box от чужого процесса этот доступ не ограничивает.

#### Verdict

Гипотеза выдержала попытку опровержения: потребность UI в диагностике объясняет происхождение ACL, но не оправдывает полный root CLI в `read`. High сохранён из-за доступности управляющих команд и секретов при низких правах; фактический exploit на роутере остаётся интеграционной проверкой.

#### Action

`FIX`, `ADD_TEST`: разнести безопасный read API и управляющие команды по разным ACL/исполняемым точкам, убрать raw JSON из read; проверить настоящей rpcd-сессией с урезанной ролью.

### F-002 — остановка DPI до завершения подготовки reload

**Original conclusion:** ошибка подготовки reload оставляет DPI-процессы остановленными. **Original severity:** High. **Validation classification:** `CONFIRMED_DEFECT`. **Final severity:** High. **Confidence:** High.

#### Observed behaviour

`service/lifecycle.uc:1570-1575` останавливает нужные Zapret/Zapret2/ByeDPI до `configure-service`, staging sing-box и nft candidate (`1591-1620`). Отказы ведут к `abort_reload(..., false)`; он не вызывает повторный `start-runtime` провайдеров (`1082-1092`). Запуск расположен лишь на успешном пути `1721-1726`.

#### Design intent

Плановый stop/start DPI перенесён из Podkop при переписывании runtime `e82d0bf5` 30.06.2026. Комментарий к позднему staging в `01472aa8c` 08.09.2026 явно защищает старый sing-box и nft от неудачной live-транзакции. Это сильный аргумент в пользу сохранения последней рабочей конфигурации, но защита охватывает не все процессы.

#### Historical reason

Вероятная причина раннего stop — исключить конфликт старого и нового DPI-процессов/портов во время reload. Явного объяснения порядка в истории нет; альтернативы не документированы. `GOOD → introducing → HEAD`: для sing-box staging улучшен в `01472aa8c`, DPI stop остался прежним.

#### Arguments that this is intentional/correct

Остановка до старта нового экземпляра предотвращает конфликт порта, NFQUEUE и двойную обработку. Обработчик возвращает ошибку, а старая nft-конфигурация не стирается.

#### Arguments that this is defective

После допустимого отказа staging сервис уже изменён: прежний DPI выключен. Старая nft-цепочка с `queue ... bypass` не заменяет userspace-провайдера; ByeDPI-путь также зависит от процесса. Есть достижимый путь без восстановления, несмотря на staged-config contract.

#### Invariant analysis

Нарушены configuration и routing invariants: неудачная операция изменяет действующий dataplane. Для ByeDPI возможна потеря маршрута, для NFQUEUE — пропуск обработки. Sing-box ownership здесь не причина.

#### Verdict

Это дефект границы транзакции, унаследованный и не устранённый поздней защитой sing-box. High сохранён: ошибка настройки способна вывести активный обход DPI из строя. Степень пользовательского воздействия зависит от режима и требует стендового наблюдения.

#### Action

`FIX`, `ADD_TEST`: готовить кандидаты до stop и сохранять/восстанавливать состояние каждого затронутого провайдера при любом отказе после stop.

### F-003 — успех reload при неудачном старте DPI

**Original conclusion:** ошибка `start-runtime` DPI игнорируется и reload сообщает успех. **Original severity:** High. **Validation classification:** `CONFIRMED_DEFECT`. **Final severity:** High. **Confidence:** High.

#### Observed behaviour

`service/lifecycle.uc:1721-1726` вызывает `module_success(..., ["start-runtime"])` без проверки возвращаемого значения. Далее записывается reload-state (`1747-1755`) и функция возвращает `0` (`1788`). В отличие от этих веток, `PRIORITY_UC` и `DNS_FAILOVER_UC` на `1707-1718` проверяют `module_status` и прерывают reload при ошибке.

#### Design intent

Код DPI пришёл с Podkop в `e82d0bf5`; `git blame` не выявил более позднего изменения этой ветки. Успешные пути других workers и комментарий `01472aa8c` о записи state после полного apply показывают желаемый контракт: committed state означает успешный переход.

#### Historical reason

Почему DPI start оставили best-effort, **Unknown**. Вероятно, это было допущение о необязательности отдельного провайдера, но commit message такого решения не фиксирует.

#### Arguments that this is intentional/correct

DPI может считаться дополнительной функцией, и отказ одного провайдера не обязан останавливать sing-box. Сохранение конфигурации позволяет работать другим режимам.

#### Arguments that this is defective

`needs_*_restart` означает, что этот провайдер необходим текущему плану; ошибки запуска не фиксируются даже как partial success. Компоненты Priority/DNS уже используют строгое условие. Успешный reload и committed state после отсутствующего DPI лишают пользователя достоверного сигнала и могут пропустить повторный запуск.

#### Invariant analysis

Нарушены configuration и isolation/routing invariants для секций, зависящих от DPI. Неудачный start не должен выдавать доказательство успешного apply.

#### Verdict

Гипотеза о сознательном best-effort не подтверждена ни документацией, ни симметрией с другими workers. Дефект доказан контрольным потоком, High сохранён из-за ложного успеха и устойчивого неверного state.

#### Action

`FIX`, `ADD_TEST`: проверять exit и readiness каждого обязательного провайдера, не записывать успешный reload-state при ошибке, определить восстановление старого состояния.

### F-004 — PID-файлы без проверки идентичности процесса

**Original conclusion:** stale PID может привести к сигналу чужому процессу. **Original severity:** Medium. **Validation classification:** `CONFIRMED_DEFECT`. **Final severity:** Medium. **Confidence:** High.

#### Observed behaviour

`singbox/dns_failover.uc:325-349`, `singbox/priority.uc:432-455` и `providers/byedpi/runtime.uc:194-247` сохраняют PID и проверяют только существование (`kill -0`) перед `TERM`, а ByeDPI может послать `KILL`. Если файл указывает на живой чужой PID, сигнал будет послан ему. Для демонстрации логического дефекта реальное PID reuse не нужно: оно лишь один способ получить stale file.

#### Design intent

DNS failover добавлен с простым worker PID в `ba3e3c891` 10.07.2026; файлы перенесены из Podkop. Цель — управлять собственным worker без сложной supervision. В более позднем sing-box ownership коде (`service/state.uc`, релиз `f05b0d06`) проверка идентичности процесса уже признана важной.

#### Historical reason

Лёгкий PID-файл ограничивает зависимости и сложность на OpenWrt. Сведений, что автор сознательно допустил убийство чужого процесса после reuse, нет.

#### Arguments that this is intentional/correct

`/var/run` обычно временный, PID reuse требует смерти worker и повторного распределения номера, а штатный stop вызывается вскоре после start. Поэтому вероятность мала.

#### Arguments that this is defective

Редкость не защищает safety invariant: `kill -0` подтверждает только существование номера. В старом файле нет starttime/команды, а `KILL` ByeDPI усугубляет эффект. Нынешняя модель sing-box показывает доступный способ проверки владельца.

#### Invariant analysis

Нарушен ownership invariant для собственных workers и потенциально чужих системных процессов. Medium сохранён из-за тяжёлого, но узкого и редкого условия.

#### Verdict

Это не просто технический долг: для достижимого состояния «PID-файл указывает на чужой процесс» результат команды однозначно ошибочен. Наблюдения реального PID reuse нет, поэтому оценка частоты ограничена.

#### Action

`FIX`, `ADD_TEST`: хранить PID и `/proc/PID/stat` starttime, сверять исполняемый файл/argv перед каждым сигналом, особенно перед ByeDPI `KILL`; тестировать с безвредным чужим процессом в namespace.

### F-005 — hostname Bootstrap DNS без resolver

**Original conclusion:** валидатор допускает hostname Bootstrap DNS, генератор не обеспечивает его разрешение. **Original severity:** Medium. **Validation classification:** `INCOMPLETE_FEATURE`. **Final severity:** Medium. **Confidence:** High.

#### Observed behaviour

`config/validator.uc:888-941` одинаково принимает hostname для main и bootstrap. `singbox/dns.uc:128-130` добавляет `domain_resolver` hostname main DNS, а `bootstrap_server()` (`136-144`) для hostname bootstrap этого не делает. При этом [sing-box UDP DNS](https://sing-box.sagernet.org/configuration/dns/server/udp/) прямо требует `domain_resolver`, если `server` — доменное имя. `route.default_domain_resolver` (`dns.uc:250-253`) не является доказательством безопасного независимого resolver для bootstrap и может ссылаться на тот же контур.

#### Design intent

Общий валидатор и bootstrap генератор появились в Podkop commit `ba3e3c891` при добавлении prioritized DNS failover; feature допускает несколько типов адресов. Тесты DNS покрывают генерацию и стратегии, но не `sing-box check` с hostname bootstrap в поддерживаемых версиях.

#### Historical reason

Вероятнее всего, общий валидатор переиспользован для обеих групп серверов без отдельного bootstrap ограничения. Явного обоснования hostname bootstrap в истории нет.

#### Arguments that this is intentional/correct

Hostname полезен для динамических DNS endpoint; при существующем системном resolver/положительном cache некоторые конфигурации могут работать. Default bootstrap — IP, поэтому штатный сценарий не затронут.

#### Arguments that this is defective

Вход валиден по Forkop, но генерируемый объект противоречит документированному требованию sing-box. Сам bootstrap не может надёжно разрешать собственный hostname, особенно когда системный DNS отказал — именно для этого bootstrap нужен.

#### Invariant analysis

Нарушается DNS invariant для разрешённой настройки; возможна потеря DNS/routing при отказе системного резолвера. Medium сохранён, поскольку дефолт с IP безопасен, а явный hostname требует выбора пользователя.

#### Verdict

Это неполная реализация разрешённой настройки, а не общий отказ DNS. Статическая проверка и официальная спецификация достаточны для классификации; точная ошибка `sing-box check` и поведение версии 1.14.4 требуют эксперимента.

#### Action

`FIX`, `ADD_TEST`: либо валидатор должен отклонять hostname bootstrap с понятной ошибкой, либо генератор должен указывать независимый IP-based resolver без цикла; проверять `sing-box check`.

### F-006 — commit mirror feeds до завершения установки

**Original conclusion:** поздний отказ установщика оставляет изменённые package feeds. **Original severity:** Medium. **Validation classification:** `DELIBERATE_TRADEOFF`. **Final severity:** Low. **Confidence:** High.

#### Observed behaviour

`install.sh:1657-1725` начинает транзакцию feed, сохраняет резервные копии и откатывает ошибку изменения/`pkg update`. После успешного индекса `configure_apk_mirror()`/`configure_opkg_mirror()` вызывают `commit_package_mirror_transaction` (`1761`, `1791`); поздний сбой скачивания или установки пакета feed уже не откатывает. Есть persistent backups (`1718-1719`).

#### Design intent

`README.md:18-26` и `docs/releases/1.0.11.md` описывают зеркало как постоянный источник зависимостей; обещан отказ от изменения репозиториев до проверки платформы и откат **при ошибке индекса**, но не откат всего install. Commit `b3bfab23` добавил OpenWrt 24.10 mirror support и тест feed transaction; `324ad0db` расширил на платформы. Это осознанная граница транзакции feed.

#### Historical reason

Зеркало обеспечивает совместимые зависимости и продолжение установок при недоступности внешних источников. Ранний commit фиксирует рабочий repository после успешного обновления индекса; поздний пакетный отказ сам по себе не делает feed нерабочим.

#### Arguments that this is intentional/correct

Feed прошёл platform/index preflight. Его сохранение позволяет повторить установку и пользоваться зеркалом; откат может вернуть недоступный upstream и ухудшить восстановление. Сторонние feeds не переписываются.

#### Arguments that this is defective

Пользователь может ожидать all-or-nothing установки. На ограниченном overlay поздний отказ оставляет системное изменение даже без Forkop; зеркало становится новой постоянной зависимостью.

#### Invariant analysis

Upgrade/configuration invariants затронуты, но «последняя рабочая конфигурация» не уничтожается: feed подтверждён индексом и имеет backup. Выигрыш — доступные зависимости и повторяемость; потеря — атомарность всей установки. Более хороший компромисс (явный rollback после всех типов позднего отказа) **не доказан**: он может сломать восстановление.

#### Verdict

Первый аудит верно описал state, но назвал его дефектом без учёта документированной границы. Low вместо Medium: это остаточный UX-риск осознанной feed policy, не runtime fault.

#### Action

`KEEP_AND_DOCUMENT`: явно сообщать в конце неудачной установки, что проверенный mirror feed остался и где находится backup; не делать автоматический глобальный rollback.

### F-007 — частичное обновление пакетов Forkop на OPKG

**Original conclusion:** последовательные install могут оставить разные версии LuCI и backend. **Original severity:** Medium. **Validation classification:** `CONFIRMED_DEFECT`. **Final severity:** Medium. **Confidence:** High.

#### Observed behaviour

`components/action.uc:1973-2004` сначала скачивает все файлы, но на OPKG делает отдельные установки app, i18n, backend; ошибка после первого успешного шага вызывает `action_fail`, не возвращая прежние пакеты. На APK файлы передаются одним вызовом. Отдельная установка не гарантирует ровно одну версию всей тройки.

#### Design intent

Commit `5ae2b3d39` «Optimize APK Forkop release installation» 03.09.2026 намеренно сгруппировал APK-файлы, сохранив OPKG-последовательность. `README.md:37-45` обещает доведённое до конца обновление для opkg/apk. Поздние rollback-пути есть для sing-box, но не для release package set.

#### Historical reason

Причина отдельного OPKG order в commit не раскрыта; вероятные ограничения postinst и package manager не доказаны. **Unknown**, почему нельзя передать все локальные OPKG-пакеты в одну команду или сделать предварительную проверку.

#### Arguments that this is intentional/correct

Каждый вызов даёт точный текст ошибки и может учитывать postinst/порядок зависимостей. Неудача backend не удаляет старый backend, поэтому полная потеря сервиса не обязательна.

#### Arguments that this is defective

После успешного обновления app/i18n и отказа backend UI и backend заведомо разных release versions. Повторная установка вручную возможна, но обычный обновитель не обеспечивает возврата или resumable completion. Это противоречит заявленной надёжности обновления.

#### Invariant analysis

Upgrade invariant нарушен: частичный package set становится новым состоянием без автоматического восстановления. Medium сохранён: риск связан с ошибкой пакетного шага, а не каждым обновлением.

#### Verdict

Осознанный порядок не отменяет недопустимый остаточный state. APK grouping уменьшает этот риск, но не доказывает атомарность OPKG и не устраняет проблему. Нужен fault-injection test именно после первого удачного package install.

#### Action

`FIX`, `ADD_TEST`: определить безопасный preflight/совместимую группу для OPKG либо журнал и восстановление предыдущего package set; проверять отказ на каждом шаге.

### F-008 — нет проверки SHA-256 в UI updater

**Original conclusion:** UI updater ставит загруженный пакет после проверки лишь на непустоту. **Original severity:** Medium. **Validation classification:** `TECHNICAL_DEBT`. **Final severity:** Low. **Confidence:** Medium.

#### Observed behaviour

`components/action.uc:635-644,1973-2004` действительно не вычисляет checksum; `pkg_install_files_command()` для APK использует `--allow-untrusted` (`404-408`). В отличие от него, `install.sh:1625-1640,2733-2741` проверяет SHA-256 release assets; поддержка добавлена commit `0831b7cf` 01.09.2026. Это несогласованность двух путей установки, а не доказательство произвольной подмены пакета.

#### Design intent

Updater наследует локальную установку package files от Podkop (`e82d0bf5`) и использует HTTPS release/mirror endpoints. `--allow-untrusted` позволяет ставить локальный APK без repository signature; это требует доверенного канала или отдельной проверки. Почему hash добавили только в installer, **Unknown**.

#### Historical reason

Исторически installer получил hashes позднее updater; отдельный перенос проверки в updater не обнаружен. Связанный commit показывает доступную модель контроля целостности, но не документирует угрозу, которую он закрывает.

#### Arguments that this is intentional/correct

HTTPS проверяет транспорт; пакетный менеджер отклоняет неисправный формат. SHA из тех же неподписанных метаданных не защитит от компрометации самого release источника. На APK mirror repository key не обязательно применим к локальному `apk add`.

#### Arguments that this is defective

Скачанный файл может отличаться от опубликованного checksum из-за повреждения или несовпадения зеркала; updater не заметит это до package install. В installer уже есть более строгий preflight, поэтому два штатных пути дают разный уровень проверки.

#### Invariant analysis

Затронут upgrade invariant и доверие к downloaded artifact. Однако из одного отсутствия SHA при HTTPS нельзя вывести реализуемую атаку или повреждённое рабочее состояние, а checksum тех же метаданных не создаёт независимую подпись.

#### Verdict

Факт отсутствия hash подтверждён, но Medium security defect из первого аудита был сильнее доказательств. Пока это hardening debt Low. Перед переводом в defect надо установить trust contract релизов и воспроизвести принятие некорректного, но installable package без независимой проверки.

#### Action

`IMPROVE_DESIGN`: унифицировать проверку с installer, отдельно определить аутентичность метаданных/подпись; не считать добавление SHA само по себе полной защитой.

### F-009 — полная очистка nftables при работающем Forkop

**Original conclusion:** `fw4 flush` удаляет ForkopTable, а Forkop не восстанавливает её автоматически. **Original severity:** Medium. **Validation classification:** `NEEDS_RUNTIME_VALIDATION`. **Final severity:** Low. **Confidence:** Medium.

#### Observed behaviour

OpenWrt [`fw4` script](https://github.com/openwrt/firewall4/blob/master/root/sbin/fw4) различает `reload` (перестраивает `inet fw4`), `stop` (удаляет `inet fw4`) и `flush` (удаляет **все** nft-таблицы). Forkop применяет отдельную `inet ForkopTable`; `service/initd.uc:770-789` слушает config и WAN events, но не событие полного `fw4 flush`. Статически таблица будет удалена, но точный route последующих пакетов с включёнными policy rules и состоянием conntrack в этой среде не измерен.

#### Design intent

Отдельная таблица защищает правила Forkop от обычного `fw4 reload`; тот не удаляет её. Эта структура и trigger plan унаследованы от Podkop (`e82d0bf5`); явного обещания восстановления после административного полного flush в README не найдено.

#### Historical reason

Forkop не встраивается в таблицу `fw4`, чтобы независимый reload firewall не стирал его dataplane. Причина отсутствия recovery после полного flush — **Unknown**.

#### Arguments that this is intentional/correct

`fw4 flush` — намеренное удаление всех таблиц администратором, обычно не часть нормального reload. Автоматически переустанавливать таблицу после этой команды может нарушить ожидаемое состояние обслуживания. Поведение обычного `fw4 reload` безопаснее, чем подразумевал первый обзор.

#### Arguments that this is defective

Если full flush вызван внешней процедурой обслуживания без намерения отключить Forkop, работающий sing-box и статус сервиса могут создать ложное ожидание активной маршрутизации. Поток может сменить путь без сигнализации.

#### Invariant analysis

Потенциально затронуты routing/fail-closed invariants, но для утверждения о direct traffic нужны packet trace и сетевой стенд. Low вместо Medium: сценарий требует явного глобального flush и не касается штатного `fw4 reload`.

#### Verdict

Первый аудит доказал удаление таблицы, но не доказал пользовательский ущерб или контракт восстановления после полной очистки. Это не основание исправлять trigger вслепую; необходим сетевой эксперимент и решение, должен ли full flush оставаться управляемым администратором отключением.

#### Action

`RUNTIME_TEST_REQUIRED`: проверить оба `fw4 reload` и `fw4 flush`, затем решить, нужен ли status alert или управляемый recovery.

### F-010 — direct fallback загрузки компонентов при выбранном proxy

**Original conclusion:** при отказе service proxy компонентный updater повторяет запрос напрямую. **Original severity:** Medium. **Validation classification:** `DELIBERATE_TRADEOFF`. **Final severity:** Medium. **Confidence:** High.

#### Observed behaviour

`components/action.uc:597-632` сначала использует `service_proxy_address()`, затем при ошибке пишет `retrying directly` и вызывает `http_get_once(..., "")`. `singbox/runtime.uc:507-520` привязывает цель `components` к UCI `download_components_via_proxy` и выбранной секции. Fallback происходит также когда прокси-адрес пуст из-за неработающего sing-box (`action.uc:560-566`).

#### Design intent

Прямой retry явно заложен в Podkop при ucode rewrite `e82d0bf5` 30.06.2026; split списка/компонентов (`918013aa`, 22.06.2026) сохранил отдельную policy. `README.md:8,18-26,37-45` подчёркивает доведение обновления до конца и fallback метаданных на GitHub. Это сильное объяснение availability-first выбора. В логах fallback не скрыт.

#### Historical reason

Уменьшение числа неудачных обновлений при недоступности локального proxy. Был ли прямой retry согласован с пользователем, который включил именно `download_components_via_proxy`, **Unknown**.

#### Arguments that this is intentional/correct

Компоненты могут быть нужны для ремонта самого proxy; жёсткое требование proxy создало бы замкнутый отказ обновления. По умолчанию proxy mode выключен, а retry явно логируется.

#### Arguments that this is defective

При явно выбранном proxy mode прямой запрос может нарушить ожидание маршрута и раскрыть запрос/адрес через WAN. Компонентный downloader не различает «proxy выбран ради доступности» и «direct запрещён policy». Лог после попытки не позволяет предотвратить side effect.

#### Invariant analysis

Выигрыш — восстановление обновления при отказе proxy; потеря — строгий routing/fail-closed invariant для update traffic. Более узкий компромисс возможен: разрешать direct fallback по отдельной опции с явным согласием, а выбранный proxy-only режим завершать ошибкой. Его техническая реализуемость видна из двух отдельных вызовов, но влияние на восстановление требует продуктового решения.

#### Verdict

Это намеренный availability fallback, а не случайный обход, поэтому прежняя формулировка «дефект» не выдержала проверки истории. Medium сохранён как существенный policy trade-off при явной настройке proxy; менять без утверждения контракта нельзя.

#### Action

`KEEP_AND_DOCUMENT`, `IMPROVE_DESIGN`: ясно назвать direct fallback в UI/документации и предложить строгий proxy-only выбор. Не отключать fallback для всех пользователей автоматически.

## Findings overturned

- **F-006:** feed transaction осознанно заканчивается после успешной проверки индекса; поздний install fault не равен неисправному feed. Остался UX-риск, но не подтверждённый дефект.
- **F-010:** direct retry явно реализован и унаследован как политика доступности. Спорной остаётся ширина этой политики для явно выбранного proxy mode; это компромисс, требующий прозрачного выбора.

F-008 понижен до technical debt, F-009 отправлен на runtime validation. Они не включены в confirmed defect backlog, но не сняты как ложные утверждения о коде.

## Confirmed defects

- **F-001:** read ACL предоставляет root CLI/raw secrets делегированному читателю.
- **F-002:** ошибка подготовки после DPI stop не восстанавливает процессы.
- **F-003:** ошибка DPI start не меняет успешный результат reload.
- **F-004:** stop по stale PID может сигналить чужому процессу.
- **F-007:** OPKG updater может оставить смешанные версии package set.

## Design decisions worth preserving

- Staged sing-box config и проверенный nft candidate из `01472aa8c`: расширять rollback на DPI, сохраняя предварительную проверку перед live transition.
- Запрет управления чужим sing-box (`service/state.uc`, `f05b0d06`): применить такую же идентификацию к worker PID, сохраняя ownership boundary.
- Проверка совместимости mirror platform и rollback feed при неудачном `pkg update` (`install.sh`, `b3bfab23`, `324ad0db`): не превращать поздний package fault в безусловное возвращение на потенциально недоступный upstream.
- Разделение download policy для списков и компонентов (`918013aa`) и сохранение последнего успешного cache: будущий proxy-only режим должен быть отдельной явной настройкой.
- Отдельная `ForkopTable`: обычный `fw4 reload` не удаляет её; не переносить правила вслепую в `inet fw4` ради случая полного flush.

## Runtime experiments required

Ниже стендовые проверки остаются нужными даже для статически подтверждённых дефектов: они измеряют реальный эффект, а не служат основанием для завышенного утверждения о проведённом испытании.

### E-001 — граница rpcd ACL (F-001)

**Environment:** тестовый OpenWrt 24.10.x с rpcd/LuCI, две сессии с отдельными read и write правами Forkop, фиктивный sing-box JSON без реальных секретов. **Steps:** проверить `ubus call session access` на `file /usr/bin/forkop exec`; затем read-сессией вызвать только `file.exec` `show_sing_box_config raw`, сравнить с masked output. На изолированном роутере повторить `stop` и восстановить сервис. **Expected if correct:** read не получает raw и не останавливает сервис. **Expected if defective:** raw доступен/stop успешен. **Evidence:** ACL grant, ubus replies, `logread`, конфиг без опубликования секрета, service state.

### E-002 — fault injection reload DPI (F-002, F-003)

**Environment:** OpenWrt 24.10.x, Forkop данного снимка, один активный Zapret или ByeDPI режим, отдельный тестовый клиент. **Steps:** снять `nft list ruleset`, `ip rule`, `ip route`, PID/порт провайдера; сделать DPI-конфигурационное изменение; после stop инжектировать отказ staging (`mktemp`/запись кандидата) и отдельно отказ `start-runtime` (недоступный тестовый binary/занятый ByeDPI порт); вызвать `/etc/init.d/forkop reload`; восстановить файлы и сервис. **Expected if correct:** ненулевой reload и прежний работоспособный dataplane, state не помечен успешным. **Expected if defective:** после staging fault провайдер отсутствует; после start fault reload возвращает 0 и новый state записан. **Evidence:** exit code, `logread`, `pgrep`, порты, snapshot state, nft/route до и после, packet capture/доступ тестового сайта.

### E-003 — stale PID ownership (F-004)

**Environment:** отдельный Linux network/PID namespace или одноразовый OpenWrt VM, временные переопределённые PID-файлы; только собственный безвредный `sleep`. **Steps:** записать PID `sleep` в test PID file DNS failover/Priority/ByeDPI, вызвать соответствующий `stop-runtime`, проверить `sleep`; повторить с подлинным worker. **Expected if correct:** чужой `sleep` жив, собственный worker остановлен. **Expected if defective:** чужой процесс получает TERM/KILL. **Evidence:** PID/starttime, cmdline, exit status, вызовы kill, test file. Не подставлять PID системной службы роутера.

### E-004 — bootstrap hostname (F-005)

**Environment:** OpenWrt 24.10.x, поддерживаемый sing-box 1.14.4 (и минимальная заявленная версия), main и bootstrap hostname, контролируемый DNS responder и отключаемый системный DNS. **Steps:** валидировать UCI, сгенерировать JSON, выполнить `sing-box check -c`, затем отключить системный resolver и запросить через sing-box тестовый домен при main/Bootstrap и detour вариантах. **Expected if correct:** проверка успешна и bootstrap получает адрес без цикла, DNS policy соблюдена. **Expected if defective:** check отклоняет JSON либо запрос зацикливается/тайм-аутится. **Evidence:** generated config, `sing-box check`, `logread`, DNS queries и packet capture.

### E-005 — частичный OPKG upgrade (F-007)

**Environment:** OpenWrt 24.10.x с OPKG, снимок всех трёх установленных пакетов и overlay backup, локальные тестовые release files. **Steps:** инжектировать отказ установки i18n или backend после удачного app install; собрать версии `opkg list-installed`, LuCI/backend ответы; проверить возможность повторения/отката. **Expected if correct:** прежний согласованный набор или автоматическое завершение новой тройки. **Expected if defective:** разные версии остаются после ошибки job. **Evidence:** package log, `opkg list-installed`, job state, `logread`, сохранённые пакеты и UI/API smoke test.

### E-006 — полный firewall flush (F-009)

**Environment:** OpenWrt 24.10.x с fw4, отдельная `ForkopTable`, тестовые LAN/wan endpoints, sing-box и явная секция proxy; снимки nft/route. **Steps:** сначала `fw4 reload` и сравнить `nft list table inet ForkopTable`; затем только на изолированном роутере `fw4 flush`, проверить таблицы/status, отправить новый TCP и DNS flow клиента; восстановить `fw4 start` и Forkop reload. **Expected if correct:** при обычном reload policy неизменна; при полном flush поведение соответствует явно определённому контракту (предупреждение/managed recovery либо осознанная остановка). **Expected if defective:** сервис заявляет active proxy, а новый flow уходит direct без предупреждения. **Evidence:** `nft list ruleset`, `ip rule`, `ip route`, `logread`, process state, DNS answer, WAN packet capture и адрес egress.

### E-007 — выбранный proxy и direct fallback (F-010)

**Environment:** тот же OpenWrt, proxy endpoint с управляемым отказом, тестовые mirror и WAN capture, `download_components_via_proxy=1`. **Steps:** начать проверку/скачивание компонента, отказать proxy, наблюдать запросы и job log; повторить с proxy disabled. **Expected if correct:** для явно выбранного strict режима direct нет; если продуктовый контракт разрешает fallback, UI заранее предупреждает. **Expected if defective:** при обещании proxy-only endpoint запрашивается direct. **Evidence:** `logread`, updater job, proxy log, WAN capture, UCI и выбранная секция.

## Validated remediation backlog

| Finding | Classification | Severity | Confidence | Recommended action |
| ------- | -------------- | -------- | ---------- | ------------------ |
| F-001 | CONFIRMED_DEFECT | High | High | Разделить ACL read/write и убрать raw secrets из read; rpcd test. |
| F-002 | CONFIRMED_DEFECT | High | High | Восстанавливать DPI после любого failed reload; staging до stop. |
| F-003 | CONFIRMED_DEFECT | High | High | Проверять DPI start/readiness до commit reload-state. |
| F-004 | CONFIRMED_DEFECT | Medium | High | Проверять идентичность PID перед TERM/KILL. |
| F-005 | INCOMPLETE_FEATURE | Medium | High | Запретить hostname bootstrap или дать ему независимый resolver; sing-box check. |
| F-007 | CONFIRMED_DEFECT | Medium | High | Сделать OPKG upgrade согласованным или восстанавливаемым при частичном отказе. |

F-010 не включён: более узкий режим proxy-only выглядит технически возможным, но его предпочтительность для всех пользователей и контракт восстановления при отказе proxy не доказаны. F-008/F-009 также не являются подтверждённым backlog дефектов.

## Do not change

- Не удалять проверку mirror platform/index и резервные копии feeds ради иллюзии «атомарности» всей установки.
- Не считать обычный `fw4 reload` эквивалентом `fw4 flush`; не переносить отдельную таблицу Forkop в `fw4` без доказанного требования.
- Не выключать direct fallback компонентов для всех пользователей без решения о proxy-only contract и процедуре восстановления, когда прокси сломан.
- Не убирать staging JSON/nft и проверку ownership sing-box при исправлении DPI reload/PID.
- Не считать локальный SHA-256, взятый из того же неподписанного release metadata, самостоятельной защитой от компрометации источника.
