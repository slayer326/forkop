// Architecture-independent WireGuard profile validation. Never execute profile text.
let ip = require("core.ip");

function invalid(message) { die(message); }
function key(value) {
    return type(value) == "string" && match(value, /^[A-Za-z0-9+\/]{43}=$/) != null;
}
function host(value) {
    return ip.valid_ip(value) || (length(value) <= 253 &&
        match(value, /^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$/) != null && index(value, "..") < 0);
}
function endpoint(value) {
    let m = match(value, /^\[([0-9A-Fa-f:]+)\]:([0-9]+)$/) || match(value, /^([^:]+):([0-9]+)$/);
    if (m == null || !host(m[1]) || int(m[2]) < 1 || int(m[2]) > 65535)
        invalid("Invalid WARP endpoint");
    return { host: m[1], port: int(m[2]) };
}
function numbers(value, minimum, maximum) {
    if (match(value, /^[0-9]+$/) == null || int(value) < minimum || int(value) > maximum)
        invalid("Invalid numeric profile field");
    return int(value);
}
function parse(text, kind) {
    if (type(text) != "string" || length(text) > 32768 || length(text) == 0)
        invalid("Profile must be a non-empty WireGuard configuration, at most 32 KiB");
    if (kind != "wireguard" && kind != "amneziawg") invalid("Unsupported tunnel type");
    let group = "", values = {}, seen = {};
    for (let line in split(replace(text, /\r/g, ""), "\n")) {
        line = trim(line);
        if (line == "" || substr(line, 0, 1) == "#" || substr(line, 0, 1) == ";") continue;
        let header = match(line, /^\[(Interface|Peer)\]$/);
        if (header != null) {
            group = header[1];
            if (seen[group]) invalid("Only one Interface and one Peer are supported");
            seen[group] = true;
            continue;
        }
        let m = match(line, /^([A-Za-z][A-Za-z0-9]*)[ \t]*=[ \t]*(.+)$/);
        if (m == null || group == "") invalid("Invalid profile line");
        let name = group + "." + m[1];
        if (values[name] != null) invalid("Duplicate profile field");
        let allowed = group == "Interface"
            ? [ "PrivateKey", "Address", "DNS", "MTU", "ListenPort", "Jc", "Jmin", "Jmax", "S1", "S2", "S3", "S4", "H1", "H2", "H3", "H4", "I1", "I2", "I3", "I4", "I5" ]
            : [ "PublicKey", "PresharedKey", "Endpoint", "AllowedIPs", "PersistentKeepalive" ];
        if (index(allowed, m[1]) < 0) invalid("Unsupported profile field; hooks and routing commands are not allowed");
        values[name] = trim(m[2]);
    }
    if (!key(values["Interface.PrivateKey"]) || !key(values["Peer.PublicKey"])) invalid("Invalid WireGuard key");
    let addresses = [];
    for (let value in split(values["Interface.Address"] || "", /[ ,\t]+/)) {
        if (!ip.valid_ip_cidr(value) ||
            (ip.valid_ipv4_cidr(value) ? substr(value, -3) != "/32" : substr(value, -4) != "/128"))
            invalid("WARP interface addresses must be host prefixes (/32 or /128)");
        if (match(value, /^(0\.|127\.|169\.254\.|22[4-9]\.|2[3-5][0-9]\.|::\/|::1\/|fe80:|ff)/i) != null)
            invalid("Loopback, link-local and multicast addresses are not valid WARP addresses");
        push(addresses, value);
    }
    if (length(addresses) == 0 || length(addresses) > 8) invalid("Invalid interface addresses");
    let allowed_ips = [];
    for (let value in split(values["Peer.AllowedIPs"] || "0.0.0.0/0, ::/0", /[ ,\t]+/)) {
        if (!ip.valid_ip_cidr(value)) invalid("Invalid allowed IP range");
        push(allowed_ips, value);
    }
    if (length(allowed_ips) > 32) invalid("Too many allowed IP ranges");
    let result = {
        private_key: values["Interface.PrivateKey"], public_key: values["Peer.PublicKey"],
        addresses, allowed_ips, endpoint: endpoint(values["Peer.Endpoint"] || ""),
        mtu: numbers(values["Interface.MTU"] || "1280", 1280, 9000),
        keepalive: numbers(values["Peer.PersistentKeepalive"] || "25", 0, 65535), amnezia: {}
    };
    if (values["Peer.PresharedKey"] != null) {
        if (!key(values["Peer.PresharedKey"])) invalid("Invalid preshared key");
        result.preshared_key = values["Peer.PresharedKey"];
    }
    for (let name in [ "Jc", "Jmin", "Jmax", "S1", "S2", "S3", "S4", "H1", "H2", "H3", "H4", "I1", "I2", "I3", "I4", "I5" ]) {
        let value = values["Interface." + name];
        if (value == null) continue;
        if (kind != "amneziawg") invalid("AmneziaWG fields require the AmneziaWG tunnel type");
        if (substr(name, 0, 1) == "I") {
            if (length(value) > 1024 || match(value, /^[A-Za-z0-9<>=:.,_+\- \t]+$/) == null) invalid("Invalid AmneziaWG signature");
        }
        else if (substr(name, 0, 1) == "H" && match(value, /^[0-9]+-[0-9]+$/) != null) {
            let range = split(value, "-");
            if (numbers(range[0], 0, 4294967295) > numbers(range[1], 0, 4294967295)) invalid("Invalid AmneziaWG range");
        }
        else numbers(value, 0, substr(name, 0, 1) == "H" ? 4294967295 : name == "Jc" ? 128 : 4096);
        result.amnezia[lc(name)] = value;
    }
    if (result.amnezia.jmin != null && result.amnezia.jmax != null && int(result.amnezia.jmin) > int(result.amnezia.jmax))
        invalid("AmneziaWG minimum packet size exceeds the maximum");
    return result;
}

function from_registration(value, private_key) {
    if (type(value) != "object") invalid("Cloudflare returned an invalid registration");
    if (value.success === false) invalid("Cloudflare refused profile registration");
    value = value.result || value;
    let config = value.config || {}, peers = config.peers || [];
    if (length(peers) != 1 || !key(private_key) || !key(peers[0].public_key)) invalid("Cloudflare returned an incomplete profile");
    let address = ((config.interface || {}).addresses || {}), addresses = [];
    if (ip.valid_ipv4(address.v4 || "")) push(addresses, address.v4 + "/32");
    if (ip.valid_ipv6(address.v6 || "")) push(addresses, address.v6 + "/128");
    if (length(addresses) == 0) invalid("Cloudflare returned no interface address");
    let remote = peers[0].endpoint || {}, target = remote.v4 || remote.v6 || remote.host || "";
    // Cloudflare may return an address with a zero placeholder port.
    let m = match(target, /^\[([0-9A-Fa-f:]+)\]:[0-9]+$/) || match(target, /^([^:]+):[0-9]+$/);
    if (m != null) target = m[1];
    if (ip.valid_ipv6(target)) target = "[" + target + "]";
    let port = (remote.ports || [])[0] || 2408;
    let text = "[Interface]\nPrivateKey = " + private_key + "\nAddress = " + join(", ", addresses) +
        "\nMTU = 1280\n\n[Peer]\nPublicKey = " + peers[0].public_key + "\nEndpoint = " + target + ":" + port +
        "\nAllowedIPs = 0.0.0.0/0, ::/0\nPersistentKeepalive = 25\n";
    parse(text, "wireguard");
    return text;
}

return { parse, from_registration, key, endpoint };
