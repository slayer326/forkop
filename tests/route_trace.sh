#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TRACE="$ROOT/forkop/files/usr/lib/diagnostics/route_trace.uc"
LIB="$ROOT/forkop/files/usr/lib"
FORKOP_LIB="$LIB" ucode -L "$LIB" "$TRACE" fixture telegram.org 192.168.1.50 TCP 443 149.154.167.99 '149.154.167.99 via 192.168.1.1 dev eth0' | node -e '
const assert = require("node:assert/strict"); let text = "";
process.stdin.on("data", part => text += part).on("end", () => {
  const trace = JSON.parse(text);
  assert.equal(trace.dns.provenance, "observed");
  assert.equal(trace.interface.value, "eth0");
  assert.equal(trace.rule.provenance, "unknown");
  assert.equal(JSON.stringify(trace).includes("password"), false);
});'
FORKOP_LIB="$LIB" ucode -L "$LIB" "$TRACE" fixture 2001:db8::1 '' UDP 53 '' '' | node -e '
let text = ""; process.stdin.on("data", part => text += part).on("end", () => {
  const trace = JSON.parse(text);
  if (trace.error || trace.dns.address !== "2001:db8::1") process.exit(1);
});'
FORKOP_LIB="$LIB" ucode -L "$LIB" "$TRACE" fixture 1.1.1.1 '' TCP 443 '' '1.1.1.1 dev wan' | node -e '
let text=""; process.stdin.on("data", part => text += part).on("end", () => {
  const trace = JSON.parse(text);
  if (trace.dns.address !== "1.1.1.1" || trace.interface.value !== "wan" || trace.dns.provenance !== "simulated") process.exit(1);
});'
FORKOP_LIB="$LIB" ucode -L "$LIB" "$TRACE" fixture unknown.example '' TCP 443 '' '' | node -e '
let text=""; process.stdin.on("data", part => text += part).on("end", () => {
  const trace = JSON.parse(text);
  if (trace.dns.provenance !== "unknown" || trace.interface.provenance !== "unknown") process.exit(1);
});'
# A bare TLD ("ru") is a valid target: it resolves to nothing, the route is still calculated.
FORKOP_LIB="$LIB" ucode -L "$LIB" "$TRACE" fixture ru '' TCP 443 '' '' | node -e '
let text=""; process.stdin.on("data", part => text += part).on("end", () => {
  const trace = JSON.parse(text);
  if (trace.error) process.exit(1);
});'
if FORKOP_LIB="$LIB" ucode -L "$LIB" "$TRACE" fixture 'x;touch /tmp/forkop-injected' '' TCP 443 '' '' >/dev/null; then
    exit 1
fi
if FORKOP_LIB="$LIB" ucode -L "$LIB" "$TRACE" fixture example.org '1.2.3.4;id' TCP 443 '' '' >/dev/null; then exit 1; fi
if FORKOP_LIB="$LIB" ucode -L "$LIB" "$TRACE" fixture example.org '' TCP 65536 '' '' >/dev/null; then exit 1; fi
printf 'route_trace: PASS\n'
