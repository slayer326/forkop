#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME="$ROOT_DIR/forkop/files/usr/lib/diagnostics/runtime.uc"

{
  printf '%s\n' \
    'let sources = {};' \
    'let executable = {};' \
    'let fs = { readfile: function(path) { return sources[path]; } };' \
    'function as_string(value) { return value == null ? "" : "" + value; }' \
    'function file_executable(path) { return executable[path] == true; }'
  awk '/^function zapret_manager_launcher_installed\(/ { emit = 1 }
       /^function system_info_cache_is_valid\(/ { emit = 0 }
       emit { print }' "$RUNTIME"
  printf '%s\n' \
    'let mirror = "#!/bin/sh\nhttps://mirror.infotechtg.ru/zapret-manager/proxy/raw.githubusercontent.com/Screamshow/Zapret-Manager/main/Zapret-Manager.sh\n";' \
    'let official = "https://raw.githubusercontent.com/StressOzz/Zapret-Manager/main/Zapret-Manager.sh";' \
    'let cases = [' \
    '  { name: "mirror", zms: mirror, auto: mirror, expected: true },' \
    '  { name: "official", zms: official, auto: official, expected: true },' \
    '  { name: "mixed", zms: official, auto: mirror, expected: true },' \
    '  { name: "missing", zms: official, expected: false },' \
    '  { name: "unrelated", zms: "#!/bin/sh\necho hello\n", auto: official, expected: false },' \
    '  { name: "wrong file", zms: official + ".old", auto: official, expected: false }' \
    '];' \
    'for (let test in cases) {' \
    '  sources = { "/usr/bin/zms": test.zms, "/usr/bin/zmsA": test.auto };' \
    '  executable = { "/usr/bin/zms": test.zms != null, "/usr/bin/zmsA": test.auto != null };' \
    '  if (zapret_manager_is_installed() != test.expected) die("FAIL: " + test.name + "\n");' \
    '}' \
    'print("Zapret-Manager launcher detection passed\n");'
} | ucode -
