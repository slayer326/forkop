#!/usr/bin/ucode
let fs = require("fs");
let profile = require("warp.profile");
let locks = require("core.runtime_lock");
let constants = require("core.constants");
let ip = require("core.ip");
let uci = require("core.uci");

const LIB = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const DIR = getenv("FORKOP_WARP_RUNTIME_DIR") || "/var/run/forkop-warp";
const NETWORK = getenv("FORKOP_WARP_NETWORK_FILE") || "/etc/config/network";
const PROTO = getenv("FORKOP_WARP_PROTO_DIR") || "/lib/netifd/proto";
const MODULE = LIB + "/warp/service.uc";
function str(value) { return value == null ? "" : "" + value; }
function quote(value) { return "'" + replace(str(value), /'/g, "'\\''") + "'"; }
function command(args) { return join(" ", map(args, quote)); }
function capture(args, input) {
    let pipe = fs.popen(command(args) + (input ? " < " + quote(input) : "") + " 2>/dev/null", "r");
    if (pipe == null) return { status: 1, output: "" };
    let output = pipe.read("all"), status = pipe.close();
    return { status: status > 255 ? int(status / 256) : status, output: str(output) };
}
function ok(args) { return capture(args).status == 0; }
function exists(name) { return ok([ "sh", "-c", "command -v " + quote(name) ]); }
function fail(message) { die(message); }
function private_write(path, data) {
    let out = fs.open(path, "w", 0600);
    if (out == null) fail("Cannot create private WARP state");
    let written = out.write(data);
    out.close();
    if (written != length(data) || !fs.chmod(path, 0600)) fail("Cannot save private WARP state");
}
function setup() {
    if (fs.lstat(DIR) == null) fs.mkdir(DIR, 0700);
    let stat = fs.lstat(DIR);
    if (stat == null || stat.type != "directory" || stat.uid != fs.stat("/proc/self").uid || !fs.chmod(DIR, 0700)) fail("Invalid WARP state directory");
}
function valid_id(id) { return match(str(id), /^[0-9]+-[0-9]+-[0-9]+$/) != null; }
function read_json(path) {
    try { return json(fs.readfile(path)); } catch (e) { return null; }
}
function capabilities() {
    let result = { success: true, package_manager: exists("apk") ? "apk" : exists("opkg") ? "opkg" : "", wireguard: false, amneziawg: false };
    result.wireguard = exists("wg") && fs.stat(PROTO + "/wireguard.sh") != null;
    result.amneziawg = exists("awg") && fs.stat(PROTO + "/amneziawg.sh") != null;
    return result;
}
function check_kind(kind) {
    if (kind != "wireguard" && kind != "amneziawg") fail("Unsupported tunnel type");
}
function dependencies(kind) {
    check_kind(kind);
    if (capabilities()[kind]) return { success: true };
    let pm = capabilities().package_manager, name = kind == "wireguard" ? "wireguard-tools" : "amneziawg-tools";
    if (pm == "") fail("APK or OPKG is required");
    let refresh = capture([ pm, "update" ]);
    if (refresh.status != 0) fail("Cannot refresh configured package repositories; network configuration was preserved");
    let probe = pm == "apk" ? [ pm, "add", "--simulate", name ] : [ pm, "--noaction", "install", name ];
    if (!ok(probe)) fail("No compatible tunnel package set is available for this firmware; check the configured mirror and kernel ABI");
    let install = pm == "apk" ? [ pm, "add", name ] : [ pm, "install", name ];
    if (!ok(install) || !capabilities()[kind]) fail("Tunnel components could not be prepared; network configuration was preserved");
    return { success: true };
}
function generate(request, work) {
    if (request.accept_terms !== true) fail("Accept Cloudflare terms before generating a profile");
    let tool = capabilities().wireguard ? "wg" : capabilities().amneziawg ? "awg" : "";
    if (tool == "") fail("Prepare WireGuard or AmneziaWG components first");
    let generated = capture([ tool, "genkey" ]), private_key = trim(generated.output);
    if (generated.status != 0 || !profile.key(private_key)) fail("Cannot generate a WireGuard key");
    private_write(work + "/key", private_key + "\n");
    let public = capture([ tool, "pubkey" ], work + "/key");
    if (public.status != 0 || !profile.key(trim(public.output))) fail("Cannot derive the WireGuard public key");
    let timestamp = trim(capture([ "date", "-u", "+%Y-%m-%dT%H:%M:%S.000Z" ]).output);
    let serial = substr(replace(trim(str(fs.readfile("/proc/sys/kernel/random/uuid"))), /-/g, ""), 0, 16);
    if (length(serial) != 16) fail("Cannot generate a registration identifier");
    private_write(work + "/payload", sprintf("%J", {
        key: trim(public.output), install_id: "", fcm_token: "", tos: timestamp,
        model: "PC", serial_number: serial, os_version: "", key_type: "curve25519", tunnel_type: "wireguard", locale: "en-US"
    }));
    let args = [ "curl", "--silent", "--proto", "=https", "--connect-timeout", "8", "--max-time", "25",
        "--max-filesize", "65536", "--output", work + "/response", "--write-out", "%{http_code}",
        "--header", "Content-Type: application/json; charset=UTF-8", "--header", "CF-Client-Version: a-6.35-4471",
        "--user-agent", "WARP for Android", "--data-binary", "@" + work + "/payload" ];
    if (request.via_proxy === true) {
        let proxy = capture([ "ucode", "-L", LIB, LIB + "/singbox/runtime.uc", "service-proxy-address", "lists" ]);
        let address = trim(proxy.output);
        if (proxy.status != 0 || match(address, /^127\.0\.0\.1:[0-9]+$/) == null)
            fail("The list-download section proxy is unavailable; configure it and start Forkop first");
        push(args, "--proxy", "http://" + address, "--noproxy", "");
    }
    else push(args, "--noproxy", "*");
    push(args, "https://api.devices.cloudflare.com/v0a4471/reg");
    let response = capture(args), code = trim(response.output);
    if (response.status != 0 || (code != "200" && code != "201"))
        fail("Cloudflare registration failed (HTTP " + (match(code, /^[0-9]{3}$/) != null ? code : "unavailable") + "); use an existing profile or a working section proxy");
    let text = profile.from_registration(read_json(work + "/response"), private_key);
    return { success: true, profile: text };
}
function uci_base(work) { return [ "uci", "-q", "-c", work, "-t", work + "/delta" ]; }
function network_uci(args) { return capture([ "uci", "-q", "-c", fs.dirname(NETWORK), ...args ]); }
function uci_line(path, value) { return "set network." + path + "=" + quote(value) + "\n"; }
function resolve_endpoint(host, ipv6) {
    if (ip.valid_ip(host)) {
        if (match(host, /^198\.(18|19)\./) != null || substr(lc(host), 0, 7) == "2001:2:") fail("FakeIP cannot be used as a tunnel endpoint");
        return host;
    }
    let configured = uci.get((getenv("FORKOP_CONFIG_NAME") || "forkop") + ".settings.bootstrap_dns_server");
    let servers = [ "" ];
    for (let server in type(configured) == "array" ? configured : split(trim(str(configured)), /[ \t\r\n]+/))
        if (ip.valid_ip(server) && length(servers) < 3) push(servers, server);
    for (let server in servers) {
        for (let family in ipv6 ? [ "A", "AAAA" ] : [ "A" ]) {
            let args = [ "dig", "+short", "+timeout=2", "+tries=1" ];
            if (server != "") push(args, "@" + server);
            push(args, host, family);
            let output = capture(args);
            for (let address in split(output.output, "\n")) {
                address = trim(address);
                if (!ip.valid_ip(address) || match(address, /^198\.(18|19)\./) != null || substr(lc(address), 0, 7) == "2001:2:") continue;
                return address;
            }
        }
    }
    fail("Cannot resolve a real tunnel endpoint; use an IP address or check Bootstrap DNS");
}
function check_local_routes(addresses) {
    let routes = capture([ "ip", "-4", "route", "show", "scope", "link" ]);
    if (routes.status != 0) fail("Cannot inspect local network routes; network configuration was preserved");
    function v4_number(value) {
        let parts = split(value, "."), result = 0;
        for (let part in parts) result = result * 256 + int(part);
        return result;
    }
    for (let line in split(routes.output, "\n")) {
        let route = match(line, /^([0-9.]+)(\/([0-9]+))? dev ([A-Za-z0-9_.-]+)/);
        if (route == null || substr(route[4], 0, 3) == "fkw") continue;
        let size = 1, prefix = route[3] == null ? 32 : int(route[3]);
        for (let bits = prefix; bits < 32; bits++) size *= 2;
        for (let address in addresses) {
            if (index(address, ":") >= 0) continue;
            if (int(v4_number(split(address, "/")[0]) / size) == int(v4_number(route[1]) / size))
                fail("The WARP address overlaps an existing local network; network configuration was preserved");
        }
    }
}
function import_profile(request, work) {
    let kind = request.kind || "wireguard";
    check_kind(kind);
    let name = str(request.name);
    if (match(name, /^fkw[a-z0-9_]{1,10}$/) == null) fail("Use a new interface name starting with fkw, at most 13 characters");
    let parsed = profile.parse(request.profile, kind);
    check_local_routes(parsed.addresses);
    parsed.endpoint.host = resolve_endpoint(parsed.endpoint.host, request.ipv6 === true);
    if (!capabilities()[kind]) fail("Prepare compatible tunnel components first");
    if (kind == "amneziawg") {
        if (length(parsed.amnezia) == 0) parsed.amnezia = { jc: "3", jmin: "40", jmax: "70", s1: "0", s2: "0", h1: "1", h2: "2", h3: "3", h4: "4" };
        let script = str(fs.readfile(PROTO + "/amneziawg.sh"));
        for (let field, value in parsed.amnezia)
            if (index(script, field) < 0) fail("The installed AmneziaWG protocol does not support all profile fields");
    }
    if (trim(network_uci([ "changes", "network" ]).output) != "") fail("Apply or discard pending OpenWrt network changes first");
    if (network_uci([ "get", "network." + name ]).status == 0 || network_uci([ "get", "network." + name + "_peer" ]).status == 0 ||
        ok([ "ip", "link", "show", "dev", name ]))
        fail("The interface name is already in use; existing interfaces are never overwritten");
    let handle = fs.open(NETWORK, "r");
    if (handle == null || !handle.lock("x")) fail("Cannot lock network configuration");
    let before = fs.readfile(NETWORK), original = fs.stat(NETWORK), held = fs.stat("/proc/self/fd/" + handle.fileno());
    let published = false, candidate = "", temporary = NETWORK + ".forkop-warp";
    try {
        if (before == null || original.inode != held.inode) fail("Network configuration changed; retry");
        if (index(before, parsed.private_key) >= 0) fail("This profile is already installed; generate a separate profile for another tunnel");
        private_write(work + "/network", before);
        if (!fs.mkdir(work + "/delta", 0700)) fail("Cannot stage network configuration");
        let batch = uci_line(name, "interface") + uci_line(name + ".proto", kind) +
            uci_line(name + ".forkop_warp", "1") + uci_line(name + ".private_key", parsed.private_key) +
            uci_line(name + ".mtu", parsed.mtu) + uci_line(name + ".defaultroute", "0") +
            uci_line(name + ".peerdns", "0") + uci_line(name + ".fwmark", constants.NFT_OUTBOUND_MARK || "0x08000000");
        let count = 0;
        for (let address in parsed.addresses) {
            if (index(address, ":") >= 0 && request.ipv6 !== true) continue;
            batch += "add_list network." + name + ".addresses=" + quote(address) + "\n";
            count++;
        }
        if (count == 0) fail("Enable IPv6 for an IPv6-only profile");
        for (let field, value in parsed.amnezia) batch += uci_line(name + "." + field, value);
        batch += uci_line(name + "_peer", kind + "_" + name) +
            uci_line(name + "_peer.public_key", parsed.public_key) +
            uci_line(name + "_peer.endpoint_host", parsed.endpoint.host) + uci_line(name + "_peer.endpoint_port", parsed.endpoint.port) +
            uci_line(name + "_peer.route_allowed_ips", "0") + uci_line(name + "_peer.persistent_keepalive", parsed.keepalive);
        if (parsed.preshared_key) batch += uci_line(name + "_peer.preshared_key", parsed.preshared_key);
        for (let subnet in parsed.allowed_ips) batch += "add_list network." + name + "_peer.allowed_ips=" + quote(subnet) + "\n";
        batch += "commit network\n";
        private_write(work + "/batch", batch);
        if (capture([ ...uci_base(work), "batch" ], work + "/batch").status != 0) fail("Cannot stage the tunnel configuration");
        candidate = fs.readfile(work + "/network");
        if (candidate == null || candidate == before) fail("The staged tunnel configuration is incomplete");
        if (fs.readfile(NETWORK) != before || trim(network_uci([ "changes", "network" ]).output) != "")
            fail("Network configuration changed during preparation; retry");
        if (fs.stat("/tmp/forkop-full-uninstall.lock") != null) fail("Forkop removal is in progress");
        private_write(temporary, candidate);
        if (!fs.rename(temporary, NETWORK)) fail("Cannot publish network configuration");
        published = true;
        // netifd reconciles changed interfaces; never restart the network or WAN.
        if (!ok([ "ubus", "call", "network", "reload" ])) fail("netifd refused the tunnel configuration");
        if (!ok([ "ifup", name ])) fail("netifd could not start the tunnel");
    }
    catch (e) {
        fs.unlink(temporary);
        if (published && fs.readfile(NETWORK) == candidate) {
            ok([ "ifdown", name ]);
            private_write(temporary, before);
            if (fs.rename(temporary, NETWORK)) ok([ "ubus", "call", "network", "reload" ]);
        }
        handle.close();
        die(e);
    }
    handle.close();
    return { success: true, interface: name, message: "Interface created; save the section to use it. A successful handshake still needs to be verified." };
}
function status(name) {
    if (match(str(name), /^fkw[a-z0-9_]{1,10}$/) == null) fail("Invalid managed interface name");
    if (trim(network_uci([ "get", "network." + name + ".forkop_warp" ]).output) != "1") fail("This interface is not managed by Forkop WARP");
    let kind = trim(network_uci([ "get", "network." + name + ".proto" ]).output);
    check_kind(kind);
    let output = capture([ kind == "wireguard" ? "wg" : "awg", "show", name, "latest-handshakes" ]);
    if (output.status != 0) fail("The tunnel device is unavailable; check installed components and netifd logs");
    let latest = 0;
    for (let line in split(output.output, "\n")) {
        let fields = split(trim(line), /[ \t]+/);
        if (length(fields) == 2 && match(fields[1], /^[0-9]+$/) != null && int(fields[1]) > latest) latest = int(fields[1]);
    }
    return { success: true, interface: name, last_handshake: latest, handshake_observed: latest > 0 };
}
function start(request) {
    if (fs.stat("/tmp/forkop-full-uninstall.lock") != null) fail("Forkop removal is in progress");
    if (index([ "prepare", "generate", "import" ], request.action) < 0) fail("Unsupported WARP action");
    check_kind(request.kind || "wireguard");
    setup();
    let stamp = clock(), id = stamp[0] + "-" + stamp[1] + "-" + fs.readlink("/proc/self");
    // Keep only recent unacknowledged jobs. No profile archives live on flash.
    for (let file in fs.glob(DIR + "/*")) {
        let s = fs.lstat(file);
        if (s != null && s.type == "file" && time() - s.mtime > 600) fs.unlink(file);
    }
    if (length(fs.glob(DIR + "/*.request")) > 3) fail("A WARP operation is already pending");
    private_write(DIR + "/" + id + ".request", sprintf("%J", request));
    private_write(DIR + "/" + id + ".result", sprintf("%J", { success: true, pending: true }));
    if (system(command([ "ucode", "-L", LIB, MODULE, "worker", id ]) + " >/dev/null 2>&1 &") != 0)
        fail("Cannot start WARP worker");
    return { success: true, job_id: id };
}
function worker(id) {
    if (!valid_id(id)) return;
    setup();
    let request_file = DIR + "/" + id + ".request", request = read_json(request_file), result;
    let work = DIR + "/work-" + id, pid = str(fs.readlink("/proc/self"));
    if (!locks.acquire(DIR + "/operation.lock", pid)) {
        fs.unlink(request_file);
        private_write(DIR + "/" + id + ".result", sprintf("%J", { success: false, message: "Another WARP operation is running" }));
        return;
    }
    try {
        for (let abandoned in fs.glob(DIR + "/work-*")) {
            let stat = fs.lstat(abandoned);
            if (stat != null && stat.type == "directory" && time() - stat.mtime > 600) ok([ "rm", "-rf", abandoned ]);
        }
        if (request == null || !fs.mkdir(work, 0700)) fail("Cannot prepare WARP operation");
        if (request.action == "prepare") result = dependencies(request.kind || "wireguard");
        else if (request.action == "generate") result = generate(request, work);
        else if (request.action == "import") result = import_profile(request, work);
        else fail("Unsupported WARP action");
    }
    catch (e) { result = { success: false, message: str(e) }; }
    ok([ "rm", "-rf", work ]);
    fs.unlink(request_file);
    private_write(DIR + "/" + id + ".result", sprintf("%J", result));
    locks.release(DIR + "/operation.lock", pid);
}
function job(id, remove) {
    if (!valid_id(id)) fail("Invalid WARP job");
    let file = DIR + "/" + id + ".result", result = read_json(file);
    if (result == null) fail("WARP job expired; check the interface before retrying");
    if (remove && !result.pending) fs.unlink(file);
    return result;
}
function dispatch(method, request) {
    if (method == "capabilities") return capabilities();
    if (method == "start") return start(request);
    if (method == "job") return job(request.id, false);
    if (method == "ack") return job(request.id, true).pending ? { success: false } : { success: true };
    if (method == "status") return status(request.name);
    fail("Unknown WARP method");
}

if (ARGV[0] == "worker") { worker(ARGV[1]); exit(0); }
if (ARGV[0] == "capabilities") { print(sprintf("%J\n", capabilities())); exit(0); }
if (ARGV[0] == "rpc") {
    try {
        let input = fs.readfile("/dev/stdin");
        if (input == null || length(input) > 40000) fail("Invalid WARP request");
        print(sprintf("%J\n", dispatch(ARGV[1], json(input))));
    }
    catch (e) { print(sprintf("%J\n", { success: false, message: str(e) })); }
    exit(0);
}
return { dispatch, generate, import_profile, status, capabilities, worker };
