#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECTION_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js"
SOURCE_PO="$ROOT_DIR/fe-app-forkop/locales/forkop.ru.po"
PACKAGE_PO="$ROOT_DIR/luci-app-forkop/po/ru/forkop.po"
SOURCE_POT="$ROOT_DIR/fe-app-forkop/locales/forkop.pot"
PACKAGE_POT="$ROOT_DIR/luci-app-forkop/po/templates/forkop.pot"
CALLS_JSON="$ROOT_DIR/fe-app-forkop/locales/calls.json"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

if grep -Fq '_("Dismiss")' "$SECTION_JS"; then
  fail "Forkop modals must use Close instead of the shared LuCI Dismiss key"
fi
grep -Fq '_("Close")' "$SECTION_JS" ||
  fail "Forkop section settings modal must expose a Close action"

if grep -Fq 'http(s)://, hy2/hysteria2:// links' \
  "$SECTION_JS" "$SOURCE_PO" "$PACKAGE_PO" "$SOURCE_POT" "$PACKAGE_POT" "$CALLS_JSON"; then
  fail "Connection URL help must not advertise removed HTTP proxy links"
fi
grep -Fq 'socks4/5://, hy2/hysteria2:// links' "$SECTION_JS" ||
  fail "Connection URL help must list the remaining native proxy links"

for po in "$SOURCE_PO" "$PACKAGE_PO"; do
  awk '
    $0 == "msgid \"Close\"" {
      getline
      if ($0 == "msgstr \"Закрыть\"")
        found = 1
    }
    END { exit found ? 0 : 1 }
  ' "$po" || fail "Close must be translated as Закрыть in $po"

  if awk '
    $0 == "msgid \"Dismiss\"" {
      getline
      if ($0 == "msgstr \"Отмена\"")
        bad = 1
    }
    END { exit bad ? 0 : 1 }
  ' "$po"; then
    fail "Dismiss must not override LuCI alert closing with Отмена in $po"
  fi

  awk '
    $0 == "msgid \"Cannot save settings\"" {
      getline
      if ($0 == "msgstr \"Не удалось сохранить настройки\"")
        found = 1
    }
    END { exit found ? 0 : 1 }
  ' "$po" || fail "Cannot save settings must have a Russian translation in $po"
done

cmp -s "$SOURCE_PO" "$PACKAGE_PO" ||
  fail "source and packaged Russian catalogs must stay synchronized"
cmp -s "$SOURCE_POT" "$PACKAGE_POT" ||
  fail "source and packaged templates must stay synchronized"

# Stage 6.10: every extracted string has a Russian translation, and the
# template carries exactly the strings the code calls.
node - "$SOURCE_PO" "$SOURCE_POT" "$CALLS_JSON" <<'NODE'
const fs = require('node:fs');
const entries = (file) => {
  const text = fs.readFileSync(file, 'utf8');
  const out = new Map();
  const re = /^msgid "((?:[^"\\]|\\.)*)"\nmsgstr "((?:[^"\\]|\\.)*)"/gm;
  for (let m; (m = re.exec(text));) if (m[1] !== '') out.set(m[1], m[2]);
  return out;
};
const po = entries(process.argv[2]);
const pot = entries(process.argv[3]);
const calls = JSON.parse(fs.readFileSync(process.argv[4], 'utf8')).map((c) => c.key);
const untranslated = [...po].filter(([, str]) => str === '').map(([id]) => id);
if (untranslated.length) throw Error(`untranslated: ${untranslated.slice(0, 10).join(' | ')}`);
const unescape = (s) => s.replace(/\\(.)/g, (_m, c) => (c === 'n' ? '\n' : c === 't' ? '\t' : c));
const templ = new Set([...pot.keys()].map(unescape));
const missing = calls.filter((k) => !templ.has(k));
if (missing.length) throw Error(`called but not in the template: ${missing.slice(0, 10).join(' | ')}`);
for (const id of pot.keys()) if (!po.has(id)) throw Error(`template string missing in ru.po: ${id}`);
NODE

# Phrases are translated whole: no word glued to a translated fragment.
DIAG_TITLE="$ROOT_DIR/fe-app-forkop/src/forkop/tabs/diagnostic/helpers/getCheckTitle.ts"
if grep -Fq "_('checks')" "$DIAG_TITLE"; then
  fail "diagnostic check titles must be whole translatable phrases"
fi
SETTINGS_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/settings.js"
if grep -Eq '\.value\("(trace|debug|info|warn|error|fatal|panic)", "' "$SETTINGS_JS"; then
  fail "log levels must be translatable"
fi
if grep -Eq '"(Flash|RAM) \(' "$SETTINGS_JS"; then
  fail "storage names must be translatable"
fi
if grep -rn --include='*.ts' "'N/A'" "$ROOT_DIR/fe-app-forkop/src" | grep -v '/tests/' | grep -q .; then
  fail "N/A is shown untranslated"
fi

printf 'LuCI localization checks passed\n'
