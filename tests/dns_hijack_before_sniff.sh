#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/forkop/files/usr/lib"
ucode -L "$LIB" -e '
let route = require("singbox.route");
let tags = require("singbox.constants");
let built = route.config({ disable_quic: "0" }, {
    source_aware_dns: true,
    dns_health_inbounds: [ "health-dns-in" ]
});
let first = built.rules[0];
let second = built.rules[1];
if (first.action != "hijack-dns" || second.action != "sniff") exit(1);
if (index(first.inbound, tags.DNS_INBOUND_TAG) < 0 ||
    index(first.inbound, tags.SOURCE_DNS_INBOUND_TAG) < 0 ||
    index(first.inbound, "health-dns-in") < 0 ||
    index(first.inbound, tags.TPROXY_INBOUND_TAG) >= 0) exit(1);
if (index(second.inbound, tags.TPROXY_INBOUND_TAG) < 0) exit(1);
print("dedicated DNS is hijacked before sniffing\n");
'
