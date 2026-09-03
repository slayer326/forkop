# Публикация Forkop на Timeweb

После успешной сборки GitHub Actions скачайте артефакт
`timeweb-files-VERSION` или файл `forkop-timeweb-VERSION.tar.gz` из GitHub
Release.

1. Откройте файловый менеджер Timeweb для сайта `fold8.ru`.
2. Перейдите в корневой каталог сайта (обычно `public_html`).
3. Загрузите `forkop-timeweb-VERSION.tar.gz` и распакуйте его в этом каталоге.
4. Убедитесь, что получился каталог `public_html/forkop`, а не
   `public_html/forkop/forkop`.
5. Проверьте в браузере:
   - `https://fold8.ru/forkop/install.sh`
   - `https://fold8.ru/forkop/updates/latest.json`
   - `https://fold8.ru/forkop/releases/VERSION/forkop_VERSION.ipk`

Архив содержит всё, что нужно загрузить для конкретного релиза:

```text
forkop/
├── install.sh
├── LATEST
├── updates/
│   └── latest.json
└── releases/
    └── VERSION/
        ├── forkop_VERSION.ipk
        ├── luci-app-forkop_VERSION.ipk
        ├── luci-i18n-forkop-ru_VERSION.ipk
        ├── forkop_VERSION.apk
        ├── luci-app-forkop_VERSION.apk
        ├── luci-i18n-forkop-ru_VERSION.apk
        └── SHA256SUMS
```

Для нестандартного домена архив можно подготовить локально:

```sh
FORKOP_RELEASE_BASE_URL=https://example.com/forkop \
  ./ops/hosting/prepare-release.sh 1.0.2 filtered-bin/release filtered-bin/hosting
```

Каждый новый архив включает актуальный `install.sh` и заменяет
`updates/latest.json`. Старые каталоги в `releases/` можно оставить: они нужны
пользователям, которые ещё скачивают предыдущую версию.
