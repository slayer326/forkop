#!/usr/bin/env bash
# A library module runs as `ucode <module>.uc <mode> ...` and dispatches on
# `mode == "..."`; a mode it does not know ends in the usage error and exit 1.
# The lifecycle called singbox/runtime.uc validate-config-stage from 1.0.36 on
# without the module ever having that mode, so every manual restart and both
# bootstrap starts failed as if the configuration were invalid.
# Every mode called through a *_UC constant must be one the module dispatches.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT_DIR/forkop/files/usr/lib" <<'PY'
import pathlib
import re
import sys

lib = pathlib.Path(sys.argv[1])
sources = {path: path.read_text(encoding='utf-8') for path in sorted(lib.rglob('*.uc'))}

modes = {}
def dispatched(relative):
    if relative not in modes:
        source = sources.get(lib / relative, '')
        modes[relative] = set(re.findall(r'mode == "([^"]+)"', source))
    return modes[relative]

missing = []
checked = 0
for path, source in sources.items():
    constants = dict(re.findall(r'^const (\w+_UC) = LIB_DIR \+ "/([^"]+)";', source, re.M))
    for match in re.finditer(r'\b(\w+_UC), \[ *"([a-z0-9][a-z0-9-]*)"', source):
        relative = constants.get(match.group(1))
        if relative is None:
            continue
        if (lib / relative) not in sources:
            missing.append('%s:%d: %s does not exist' % (
                path.relative_to(lib), source.count('\n', 0, match.start()) + 1, relative))
            continue
        checked += 1
        if match.group(2) not in dispatched(relative):
            missing.append('%s:%d: %s has no mode %s' % (
                path.relative_to(lib), source.count('\n', 0, match.start()) + 1, relative, match.group(2)))

if checked < 100:
    sys.exit('FAIL: only %d module calls were recognised; the scan no longer matches the call style' % checked)
if missing:
    sys.exit('FAIL: modules are called with modes they do not dispatch:\n  ' + '\n  '.join(missing))
print('module mode dispatch checks passed (%d calls)' % checked)
PY
