#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
NFT_UC="$ROOT_DIR/forkop/files/usr/lib/nft/apply.uc"
STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$STATE_DIR"' EXIT HUP INT TERM

cat > "$STATE_DIR/guard.uc" <<'UCODE'
let fs = require("fs");
let present = false;
let applied = "";
function as_string(value) { return value == null ? "" : "" + value; }
function command_output_from_args(args) { return ARGV[0] + "/batch"; }
function run_args_quiet(args) { return present; }
function run_args(args) {
    let data = fs.readfile(args[length(args) - 1]);
    if (data == null)
        return false;
    if (args[1] == "-f") {
        applied = data;
        present = index(data, "add table") >= 0;
    }
    return true;
}
UCODE

awk '/^function nft_dpi_transition_guard\(/{copy=1} /^function nft_rebuild_runtime_from_uci\(/{copy=0} copy{print}' "$NFT_UC" >> "$STATE_DIR/guard.uc"

cat >> "$STATE_DIR/guard.uc" <<'UCODE'
if (!nft_dpi_transition_guard("ForkopTable", false))
    exit(1);
if (!present || index(applied, "hook output priority -149") < 0 ||
    index(applied, "0x01000000 drop") < 0 ||
    index(applied, "0x02000000 drop") < 0)
    exit(2);
if (nft_dpi_transition_guard("ForkopTable", false))
    exit(3);
if (!nft_dpi_transition_guard("ForkopTable", true))
    exit(4);
if (present || index(applied, "delete table inet ForkopTableDpiGuard") < 0)
    exit(5);
UCODE

ucode "$STATE_DIR/guard.uc" "$STATE_DIR"
printf 'dpi_transition_guard: PASS\n'
