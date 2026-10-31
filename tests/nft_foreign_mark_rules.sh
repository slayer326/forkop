#!/usr/bin/env bash
# The nftables diagnostic warned about "additional marking rules" for any
# "meta mark set" in another table. A DPI bypass running next to Forkop only
# ORs its own bits into the packet mark and leaves Forkop's 0x04000000 alone;
# only a rule that can set or clear that bit is a conflict.
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
STATUS_UC="$FORKOP_LIB/diagnostics/status.uc"
MARK=0x04000000

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

changes_bit() {
  printf '%s\n' "$1" | ucode -L "$FORKOP_LIB" "$STATUS_UC" nft-mark-rules-change-bit "$MARK"
}

# Rules copied from a router running Zapret2 next to Forkop.
for rule in \
  'meta nfproto ipv4 tcp dport { 80, 443, 853, 1024-65535 } ct original packets 1-25 meta mark set meta mark | 0x20000000 ct mark set ct mark | 0x40000000 queue flags bypass to 300' \
  'meta nfproto ipv4 udp sport { 53, 80, 88, 443, 1024-65535 } ct reply packets 1-3 ct mark set ct mark | 0x40000000 queue flags bypass to 300' \
  'meta mark & 0x40000000 == 0x00000000 oifname @wanif ip daddr != @nozapret jump postnat' \
  'meta mark set meta mark & 0xff00ffff | 0x00010000 counter' \
  'meta mark set meta mark | 256 accept'; do
  if changes_bit "$rule"; then
    fail "a rule that keeps Forkop's mark bit was reported: $rule"
  fi
done

for rule in \
  'iifname "br-lan" meta mark set 0x00000010 counter' \
  'meta mark set meta mark | 0x04000000' \
  'meta mark set meta mark & 0xfbffffff' \
  'meta mark set meta mark ^ 0x0c000000' \
  'ct state established meta mark set ct mark'; do
  changes_bit "$rule" || fail "a rule that can change Forkop's mark bit was not reported: $rule"
done

ruleset='table inet zapret2 {
	chain postrouting {
		meta nfproto ipv4 tcp dport 443 meta mark set meta mark | 0x20000000 ct mark set ct mark | 0x40000000 queue flags bypass to 300
	}
}
table inet ForkopTable {
	chain mangle {
		iifname @forkop_interfaces meta l4proto tcp meta mark set 0x04000000 counter packets 0 bytes 0
	}
}
table inet mwan3 {
	chain mwan3_rules {
		meta mark set 0x00000100 counter
	}
}'
lines="$(printf '%s\n' "$ruleset" | ucode -L "$FORKOP_LIB" "$STATUS_UC" nft-ruleset-other-mark-lines ForkopTable "$MARK")"
[ "$(printf '%s\n' "$lines" | grep -c .)" = 1 ] && printf '%s\n' "$lines" | grep -q 'meta mark set 0x00000100' ||
  fail "the listing must show only the conflicting rule outside Forkop's table: $lines"

printf 'foreign nftables mark rule checks passed\n'
