#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/forkop/files/usr/lib"
ACTION="$LIB/components/action.uc"
check() {
    actual="$(ucode -L "$LIB" "$ACTION" managed-runtime-active-fixture "$2" "$3")"
    [ "$actual" = "$1" ] || {
        echo "FAIL: managed runtime active=$2 service=$3 returned $actual" >&2
        exit 1
    }
}
check 1 0 1
check 0 1 1
check 0 0 0
check 0 '' 1
echo 'managed runtime state checks passed'
