#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

ucode -L "$FORKOP_LIB" "$ROOT_DIR/tests/reality_xhttp.uc" "$WORK_DIR" "$FORKOP_LIB"
