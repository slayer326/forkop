# Независимая проверка исправлений `bbd7a2d8..bf7da516`

Эти выводы основаны на чтении исполняемого кода и воспроизведениях в локальной WSL-среде. `AUDIT_VALIDATION.md` и `FIX_VALIDATION.md` использовались только как описание намерения. Проверка на маршрутизаторе OpenWrt не проводилась.

## R-001 — интерфейс для пользователя только с правом чтения

- **Finding:** основной LuCI view не открывался при отказе UCI `forkop`.
- **Original regression:** `form.Map("forkop")` выполнял загрузку всего UCI package до рендера безопасных dashboard/diagnostics. На `bf7da516` сценарий `read ACL + UCI Permission denied` в `tests/luci_readonly_view.sh` завершался ошибкой.
- **Root cause:** ACL F-001 правильно ограничил чтение UCI, но view продолжал требовать полный UCI package.
- **Fix:** для read-only используется `form.JSONMap` с безопасными данными; пользователь с правом записи сохраняет обычный `form.Map`.
- **Invariant:** доступ к dashboard/diagnostics не даёт права читать секреты UCI, raw outbound и sing-box configuration.
- **Regression test:** `tests/luci_readonly_view.sh` и `tests/acl_boundary.sh`.
- **Adversarial test:** отдельно проверены путь записи, отсутствие полной загрузки UCI в read-only path и сохранение ACL-запрета на секретные методы.
- **Remaining OpenWrt validation:** rpcd read-only session и реальный рендер LuCI с отказом UCI.
- **Commit SHA:** `c5466cb9`.

## R-002 — состояние сервиса после отката OPKG

- **Finding:** откат пакетов мог оставить ранее работающий Forkop остановленным.
- **Original regression:** на `bf7da516` fault test с ошибкой установки backend возвращал прежние версии, но сервис оставался stopped; `tests/forkop_opkg_set.sh` падал на этом сценарии.
- **Root cause:** package `prerm`/`postinst` используют transient marker, который повторный `prerm` при `--force-reinstall` может перезаписать; transaction-level состояние не сохранялось.
- **Fix:** исходное состояние сервиса записывается вместе с версиями в durable `pending` до первой package mutation; после отката проверяется исходное состояние сервиса, и marker удаляется только после этого. Для marker старого формата с неизвестным состоянием сервис не угадывается, архив сохраняется для ручного восстановления.
- **Invariant:** завершённый rollback возвращает версии и исходное состояние сервиса; при неудачном запуске recovery evidence остаётся.
- **Regression test:** `tests/forkop_opkg_set.sh` охватывает running/stopped, повторный `prerm`, прерванный recovery, повторную попытку запуска, legacy marker и ошибку старта.
- **Adversarial test:** проверены повторное восстановление при уже откатанных версиях, отказ переустановки одного пакета и удержание архива; `tests/package_lifecycle.sh`, `tests/package_upgrade_wait.sh` и `tests/package_contract.sh` проходят.
- **Remaining OpenWrt validation:** реальные OPKG `prerm/postinst`, readiness после restart, недостаток overlay space и power-loss recovery.
- **Commit SHA:** `f217535`.

## R-003 — stale PID DPI и rollback

- **Finding:** мёртвый supervisor с оставшимся pidfile блокировал восстанавливающий reload.
- **Original regression:** `tests/dpi_runtime_snapshot.sh` с завершённым настоящим supervisor и stale pidfile падал на `bf7da516` до перехода DPI.
- **Root cause:** snapshot трактовал любой мёртвый PID как hard failure; `restore()` также записывал только PID без starttime, необходимого для безопасной эскалации до KILL.
- **Fix:** snapshot отличает подтверждённо мёртвый supervisor от живого чужого/повторно использованного PID и surviving child; stale запись не блокирует попытку reload, но отмечается как невосстановимая при rollback. Restore записывает PID со starttime через `process_identity.record()`.
- **Invariant:** живые неоднозначные процессы не получают сигнала; при невозможности вернуть stale runtime защитный guard не снимается как после успешного rollback.
- **Regression test:** `tests/dpi_runtime_snapshot.sh` создаёт и завершает supervisor, проверяет stale, foreign, PID reuse, surviving/orphan child и KILL восстановленного supervisor.
- **Adversarial test:** `tests/dpi_reload_faults.sh`, `tests/dpi_transition_guard.sh`, `tests/foreign_pid_stop.sh`; дополнительно проверена принадлежность supervisor через `process_identity.matches()`.
- **Remaining OpenWrt validation:** настоящие ByeDPI, Zapret и Zapret2 supervisor/child, nft transition guard и rollback при отказе start-runtime.
- **Commit SHA:** `45e02d9`, дополнения `ef9c664`, `e6772d2`.

## R-004 — граница процесса после OPKG recovery

- **Finding:** после отката A ← B текущий процесс, загруженный из B, продолжал сравнивать установленный A-set с `FORKOP_VERSION=B`.
- **Original regression:** `tests/forkop_recovery_boundary.sh` на `bf7da516` показывает переход к install logic после успешного recovery и ложную ошибку о несовместимых версиях.
- **Root cause:** recovery возвращал пустую строку, после чего `component_action()` продолжал работу с прежними загруженными константами.
- **Fix:** после успешного recovery action возвращает отдельный результат `recovered` и завершается; frontend сообщает, что новая попытка обновления ещё не выполнялась, затем перезагружает страницу. Следующий вызов загружает установленную версию backend заново.
- **Invariant:** текущий процесс никогда не принимает решение о новом обновлении после отката собственного backend.
- **Regression test:** `tests/forkop_recovery_boundary.sh` проверяет recovery, отдельный fresh invocation, ошибку recovery и сохранение marker; `tests/forkop_opkg_set.sh` проверяет service state.
- **Adversarial test:** проверены успешная повторная попытка, отказ recovery без продолжения установки и отсутствие ложного статуса `latest` в UI при `recovered`.
- **Remaining OpenWrt validation:** реальное поведение rpcd/component-action после замены backend, повторный вызов из LuCI и перезагрузка view.
- **Commit SHA:** `b739ed4`.

## Cross-fix compatibility

- **OPKG recovery state:** `PREPARED` — архивы и preflight до marker; `MUTATING` — durable `pending` записан и синхронизирован до первого `opkg install`; `ROLLBACK_REQUIRED` — версии не равны целевому набору; `ROLLBACK_PACKAGES_DONE` — версии старого набора подтверждены; `SERVICE_STATE_RESTORED` — сервис проверен в исходном состоянии; `RECOVERY_COMPLETE` — marker удалён. При прерывании этап определяется по marker, версиям пакетов и проверке сервиса; при неизвестном старом формате marker завершение блокируется.
- **F-001 ↔ R-001:** read-only view использует разрешённые endpoint, ACL не возвращает полный UCI read.
- **F-002/F-003 ↔ R-003:** stale supervisor пропускается к контролируемому DPI switch; failure path сохраняет nft guard, если старый runtime нельзя восстановить.
- **F-004 ↔ restore:** восстановленный supervisor получает PID и starttime; foreign PID и PID reuse отклоняются.
- **F-007 ↔ R-002/R-004:** marker переживает package failure и restart failure; после успешного recovery action завершается до сравнения со старой in-memory версией.
- **DNS rollback ↔ DPI rollback:** существующие `tests/dpi_reload_faults.sh` и `tests/dpi_transition_guard.sh` проходят; реальная nft/dnsmasq транзакция на OpenWrt остаётся непроверенной.

## Локальные проверки

Целевые regression tests, frontend suite (523 теста), lint и build прошли. Полный backend suite: 123 passed, 1 failed — `tests/list_cache.sh` с `runtime generation committed despite insufficient /tmp capacity`. Это известная для данной WSL-среды проверка искусственного порога свободного места; результат не засчитан как PASS. Runtime-проверка на устройстве не выполнялась.
