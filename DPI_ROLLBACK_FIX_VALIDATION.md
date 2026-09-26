# Проверка исправления DPI rollback (R-003)

Коммит с исправлением: `2026cfd7211f28351d4d0e4e83a312eefbbeac7d`.
База проверки: `ed6ff3f815f595eaa45d2bf25353eed645c92f16`.

## Исходное воспроизведение и причина

В исходном коде `restore()` обходил snapshot по порядку. Для `[normal, {"stale":"missing"}]` он запускал normal supervisor, затем возвращал `false` из-за stale entry. Запущенный процесс оставался жить при активном fail-closed guard. Аналогично, при сбое второго normal entry первый оставался запущенным. В lifecycle восстановление old runtime могло начаться, пока new runtime после DPI switch ещё работал.

## Исправление

* До запуска любого процесса проверяются JSON shape, типы и число полей entries, уникальность имён, весь массив `args`, путь библиотеки, путь runtime и child pidfile. Любой stale, invalid или ambiguous entry делает snapshot невосстанавливаемым без запуска процессов.
* Перед восстановлением old runtime lifecycle проверяет snapshots всех задействованных провайдеров и безопасно останавливает текущие owned runtime под DPI guard. Несовпадение `process_identity`, чужой PID или ошибка остановки прерывают восстановление; old supervisors не запускаются.
* Каждый запущенный supervisor получает временную identity-запись с PID и start ticks до записи постоянного pidfile. При последующей ошибке текущий вызов останавливает свои supervisors и подтверждённых children через `process_identity`; child без pidfile ищется среди потомков именно этого supervisor. При ошибке следующего провайдера lifecycle очищает уже восстановленные провайдеры.
* При ошибке DNS rollback после DPI switch guard и snapshot сохраняются для диагностики. Stale snapshot не превращается в работающий old runtime.

## Проверки

* `tests/dpi_runtime_snapshot.sh`: PASS. Проверены оба порядка normal/stale, stale последним в трёх entries, duplicate name, ошибка второго и третьего запуска, ошибка identity record, отсутствие child pidfile, замена уже работающего new runtime и чужой PID. После ошибок тест проверяет отсутствие нового живого supervisor и child.
* `tests/dpi_reload_faults.sh`, `tests/dpi_transition_guard.sh`, `tests/process_identity.sh`, `tests/foreign_pid_stop.sh`: PASS. Проверены preflight, ошибка остановки current runtime и очистка после ошибки следующего провайдера при сохранении guard и snapshot.
* Полный backend suite в WSL: 123/124 PASS. `tests/list_cache.sh` воспроизводит известный WSL-сбой: `runtime generation committed despite insufficient /tmp capacity`. Общий suite не является PASS.
* Frontend: 523 теста PASS; lint и build PASS. `ucode -c` для изменённых `.uc` и `git diff --check`: PASS.

## Финальный self-review и оставшаяся проверка

В проверенных failure paths `restore()` не оставляет больше живых DPI-процессов, чем было перед попыткой rollback. При невозможности подтвердить ownership или остановить текущий runtime old restore не начинается; при ошибке запуска выполняется очистка только процессов текущего вызова, а guard остаётся. Если сам TERM/KILL собственного процесса не сработает, функция возвращает ошибку и guard остаётся; такой системный отказ требует ручного восстановления и не может считаться успешным rollback.

На OpenWrt-устройстве ещё требуется проверить реальный switch/rollback с nfqws и ciadpi, сохранение guard при отказах остановки и отсутствие surviving процессов после fault injection. Проверки в WSL не подтверждают аппаратную корректность.
